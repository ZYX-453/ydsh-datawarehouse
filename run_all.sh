#!/bin/bash
# =============================================================================
# 云购生活数据仓库项目 —— 第 1 周全流程一键执行脚本
# -----------------------------------------------------------------------------
# 用途：按依赖顺序执行 ODS 建库 → 建表 → 导入 → 质量评估 → DWD 建表 → 清洗 → 汇总
# 用法：
#   ./run_all.sh                 # 执行完整流程
#   ./run_all.sh ods             # 只执行 ODS 层
#   ./run_all.sh clean           # 只执行清洗层（前提：ODS 已就绪）
#
# 环境变量：
#   HIVE_CONTAINER  默认 hive-server
#   HIVE_JDBC       默认 jdbc:hive2://localhost:10000
# =============================================================================

set -uo pipefail

HIVE_CONTAINER="${HIVE_CONTAINER:-hive-server}"
HIVE_JDBC="${HIVE_JDBC:-jdbc:hive2://localhost:10000}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-ydsh-mysql}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-root}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="${1:-all}"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] $*${NC}"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] $*${NC}"; }

# ------------------------------------------------------------ 路径转换 ----
# 【必须】Docker Desktop 是 Windows 程序，不认 Git Bash 的 Unix 路径。
#   /f/企业项目实战/sql/x.sql  →  Docker 解析成 F:\f\企业项目实战\...  → 文件不存在
#   docker cp 因此失败，beeline 报 "File ... does not exist" 并返回退出码 2。
# 所有传给 docker 的宿主机路径都必须先经此函数转成 Windows 形式。
win_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        # 非 Git Bash 环境（Linux/macOS）原样返回
        printf '%s\n' "$1"
    fi
}

# ---------------------------------------------------------------- 前置检查 ----
precheck() {
    log "前置检查..."

    if ! command -v docker >/dev/null 2>&1; then
        err "未找到 docker 命令"; exit 1
    fi

    if ! docker ps --format '{{.Names}}' | grep -qx "$HIVE_CONTAINER"; then
        err "容器 $HIVE_CONTAINER 未运行。当前运行中的容器："
        docker ps --format '  {{.Names}}  ({{.Image}})'
        echo
        err "请先启动 Hive 环境，或通过 HIVE_CONTAINER 指定正确容器名"
        exit 1
    fi

    log "容器 $HIVE_CONTAINER 运行中，测试 beeline 连通性..."
    if ! docker exec "$HIVE_CONTAINER" beeline -u "$HIVE_JDBC" --silent=true -e "show databases;" >/dev/null 2>&1; then
        err "beeline 连接失败：$HIVE_JDBC"
        err "排查：docker logs --tail 50 $HIVE_CONTAINER"
        exit 1
    fi
    log "beeline 连接正常"

    # 消除噪音：beeline 会在当前用户 home 下写 .beeline 历史文件，
    # 容器内 hive 用户没有可写 home，每次执行都打印
    #   [WARN] Failed to create directory: /home/hive/.beeline
    # 该 WARN 无害，但会干扰日志阅读，也容易被误认为出错。
    if ! docker exec "$HIVE_CONTAINER" test -d /home/hive 2>/dev/null; then
        docker exec -u root "$HIVE_CONTAINER" mkdir -p /home/hive 2>/dev/null || true
        docker exec -u root "$HIVE_CONTAINER" chown hive:hive /home/hive 2>/dev/null || true
    fi
}

# ------------------------------------------------------- 原始数据预处理 ----
# 把 模拟数据/ 的 CSV 转成可被 Hive 直接导入的格式（CRLF→LF、去 BOM）
# 这一步不能省：Hive 的 LINES TERMINATED BY 只支持 '\n'，
# 而源文件是 CRLF，不转换会导致每行末字段带上 '\r'
prepare_data() {
    log "===== 原始数据预处理（CRLF→LF、去除 BOM）====="

    local py=""
    for c in python python3 py; do
        if command -v "$c" >/dev/null 2>&1; then py="$c"; break; fi
    done

    if [ -z "$py" ]; then
        err "未找到 python，无法执行数据预处理"
        err "请安装 Python 3，或手动执行："
        err "  python scripts/prepare_data.py"
        exit 1
    fi

    # 路径转换：Git Bash 下 $SCRIPT_DIR 是 Unix 风格（/f/项目），
    # Windows 版 Python 不认这种路径，需用 cygpath 转成 F:\项目
    local py_script="$SCRIPT_DIR/scripts/prepare_data.py"
    if command -v cygpath >/dev/null 2>&1; then
        py_script="$(cygpath -w "$py_script")"
    fi

    if ! "$py" "$py_script"; then
        err "数据预处理失败，终止执行"
        exit 1
    fi
    echo
}

# ------------------------------------------------------------ 执行单个脚本 ----
run_sql() {
    local f="$1"
    local base log_file
    base="$(basename "$f")"
    log_file="$LOG_DIR/${base%.sql}.log"

    if [ ! -f "$f" ]; then
        err "文件不存在：$f"; return 1
    fi

    log "执行 $base"

    # ① 传输 SQL 到容器，并【验证确实到位】
    #   两个坑都要防：
    #     a) 宿主路径必须是 Windows 形式，否则 docker cp 失败（见 win_path 说明）
    #     b) 必须删掉容器内旧文件，否则 cp 失败时残留的旧文件会让 test -f 通过，
    #        导致「看起来成功、实际执行的是上次的 SQL」—— 比直接报错更危险
    local src_path
    src_path="$(win_path "$f")"
    # docker cp 写入的文件属 root，删除需用 root 身份，否则 rm 会静默失败
    docker exec -u root "$HIVE_CONTAINER" rm -f "/tmp/$base" 2>/dev/null || true

    if ! docker cp "$src_path" "$HIVE_CONTAINER:/tmp/$base" >/dev/null 2>&1 \
       || ! docker exec "$HIVE_CONTAINER" test -s "/tmp/$base" 2>/dev/null; then
        err "SQL 文件传输到容器失败：$base"
        err "  源路径：$src_path"
        err "请检查该文件是否存在、容器 $HIVE_CONTAINER 是否正常"
        return 1
    fi

    # ② 执行并把输出写入日志文件
    docker exec "$HIVE_CONTAINER" \
        beeline -u "$HIVE_JDBC" --silent=true --force=true -f "/tmp/$base" 2>&1 \
        | tee "$log_file"
    local rc=${PIPESTATUS[0]}

    # ③ 双重判定：退出码 + 日志中的 Error
    #   注意：--force=true 会让 beeline 忽略 SQL 错误并返回 0，
    #   所以只看退出码会漏掉真正的 SQL 报错，必须同时扫描日志。
    local sql_err
    sql_err="$(grep -i -E "^Error|FAILED:|SemanticException|does not exist" "$log_file" \
               | grep -v "Failed to create directory" | head -5)"

    if [ $rc -ne 0 ] || [ -n "$sql_err" ]; then
        err "$base 执行失败（退出码 $rc）"
        if [ -n "$sql_err" ]; then
            err "错误详情："
            echo "$sql_err" | sed 's/^/    /' >&2
        fi
        err "完整日志：$log_file"
        return 1
    fi
    log "$base 完成"
    echo
}

# ---------------------------------------------------------------- 分阶段 ----
# --------------------------------------------------- Metastore 字符集修复 ----
# Hive 官方 schema 把元数据表建成了 latin1，导致建表时的中文注释被存成 '?'。
# 只转换注释类字段（不参与索引，不受 3072 字节索引长度限制）。
# 幂等：重复执行无副作用；环境重建后必须执行一次。
fix_charset() {
    log "===== 修复 Metastore 字符集（中文注释）====="
    local f="$SCRIPT_DIR/sql/fix/fix_metastore_charset.sql"
    if [ ! -f "$f" ]; then
        warn "未找到 $f，跳过（中文注释可能显示为 ?）"
        return 0
    fi
    # 用 stdin 重定向把脚本喂给容器内的 mysql，避免 docker cp 的路径转换问题；
    # 密码通过 MYSQL_PWD 环境变量传递，不出现在命令行里。
    if docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$MYSQL_CONTAINER" \
            mysql -uroot < "$f" >/dev/null 2>&1; then
        log "字符集修复完成"
    else
        warn "字符集修复失败（不影响数据，仅影响注释显示）"
    fi
}

run_ods() {
    log "========== 阶段 1/2：ODS 贴源层 =========="
    fix_charset || exit 1
    run_sql "$SCRIPT_DIR/sql/ods/01_create_database.sql"        || exit 1
    run_sql "$SCRIPT_DIR/sql/ods/02_create_ods_tables.sql"      || exit 1
    run_sql "$SCRIPT_DIR/sql/ods/03_load_ods_data.sql"          || exit 1
    run_sql "$SCRIPT_DIR/sql/quality/01_quality_assessment.sql" || exit 1
}

run_clean() {
    log "========== 阶段 2/2：DWD 明细层与数据清洗 =========="
    run_sql "$SCRIPT_DIR/sql/clean/01_create_dwd_tables.sql"        || exit 1
    run_sql "$SCRIPT_DIR/sql/clean/02_handle_missing_values.sql"    || exit 1
    run_sql "$SCRIPT_DIR/sql/clean/03_deduplicate_orders.sql"       || exit 1
    run_sql "$SCRIPT_DIR/sql/clean/04_cleaning_summary.sql"         || exit 1
}

# ------------------------------------------------------------------ main ----
precheck

# 只要涉及 ODS 导入，就必须先做数据预处理
case "$STAGE" in
    ods|all) prepare_data ;;
esac

case "$STAGE" in
    ods)   run_ods ;;
    clean) run_clean ;;
    all)   run_ods; run_clean ;;
    *)
        err "未知参数：$STAGE（可选：all / ods / clean）"
        exit 1
        ;;
esac

log "全部执行完毕。"
log "结果核对要点："
echo "  · ODS 行数：1000 / 600 / 60 / 15600 / 37549 / 60000"
echo "  · DWD 行数：1000 / 600 / 15000（订单去重后）"
echo "  · BOM 与 CRLF 残留检查结果应为 0"
echo "  · 明细表孤儿订单数应为 0"
