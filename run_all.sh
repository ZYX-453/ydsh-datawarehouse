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

# =============================================================================
# 【必须】禁用 Git Bash (MSYS) 的自动路径转换
#
# 现象：执行 docker exec hive-server ls /sql/ods/ 报
#   ls: cannot access 'G:/Work/Codex/Git/Git/sql/ods/': No such file or directory
# 注意报错里的路径不是 /sql/ods/，而是被拼到了 Git 安装根目录下。
#
# 原因：MSYS 会把传给外部程序（docker.exe）的、看起来像 Unix 绝对路径的参数
# 自动转换成 Windows 路径。规则是把「/xxx」映射到「<MSYS 安装根>/xxx」，
# 所以 /sql/ods/ 变成了 <Git安装目录>/sql/ods/，容器里自然找不到。
# （容器内路径 /sql 并未改变，只是宿主端传参时被改写了）
#
# 解决：MSYS_NO_PATHCONV=1 关闭转换；MSYS2_ARG_CONV_EXCL='*' 是所有参数都不转换。
# 这两个变量在部分终端环境（如 CI、某些 IDE 内置 bash）可能已预设，
# 但在原生 Git Bash 窗口里通常没有 —— 这正是「脚本在 A 处能跑、B 处报错」的根源。
# 故此处显式设置，不依赖外部环境。
# =============================================================================
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

HIVE_CONTAINER="${HIVE_CONTAINER:-hive-server}"
HIVE_JDBC="${HIVE_JDBC:-jdbc:hive2://localhost:10000}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-ydsh-mysql}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-root}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="${1:-all}"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { printf '%b%s %s%b\n' "$GREEN" "[$(date +%H:%M:%S)]" "$*" "$NC"; }
warn() { printf '%b%s %s%b\n' "$YELLOW" "[$(date +%H:%M:%S)]" "$*" "$NC"; }
# 注意：这里用 printf '%b' 而非 echo -e 来输出颜色。
#   echo -e 会把参数中的反斜杠序列当转义处理，
#   而 Windows 路径里存在 \01、\07 这类形态（如 sql\ods\01_xxx.sql），
#   会被解释成八进制控制字符 \x01、\x07 直接吞掉，导致打印出的路径缺字符，
#   排查时极易误判。printf '%b' 只对格式串生效，参数按原样输出。
err()  { printf '%b%s %s%b\n' "$RED" "[$(date +%H:%M:%S)]" "$*" "$NC"; }

# ------------------------------------------------------------ 路径显示 ----
# 把 Git Bash 的 Unix 路径转成 Windows 形式，仅用于错误提示中给人看的可读路径。
# （脚本本身不再把宿主路径交给 docker，改为直接执行容器内挂载路径 /sql/...）
# 例：/f/企业项目实战/sql/x.sql  →  F:\企业项目实战\sql\x.sql
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
    local base log_file cpath
    base="$(basename "$f")"
    log_file="$LOG_DIR/${base%.sql}.log"

    # 把宿主机绝对路径换算成容器内路径。
    # 容器把宿主机 <项目>/sql 挂载为 /sql（见 docker-compose.yml），
    # 所以 /项目/sql/ods/01_x.sql 在容器内就是 /sql/ods/01_x.sql。
    cpath="/sql/${f#"$SCRIPT_DIR"/sql/}"

    if [ ! -f "$f" ]; then
        err "文件不存在：$(win_path "$f")"; return 1
    fi

    # 【为什么直接执行容器内路径，不再传输文件】
    #   此前两种"把脚本搬进容器"的方式在 Git Bash 环境都不可靠：
    #     ① docker cp        —— 依赖宿主路径解析，Windows + 中文路径下不稳
    #     ② docker exec -i + stdin 重定向
    #        —— Git Bash（mintty 伪终端）下子进程拿不到重定向内容，
    #           会生成 0 字节文件，3 次重试全失败
    #   改为把 sql/ 目录直接挂进容器后，脚本本来就在容器里，没有"传输"这个环节，
    #   不可能失败，也不再有残留旧文件导致"执行了上一轮 SQL"的隐患。
    if ! docker exec "$HIVE_CONTAINER" test -s "$cpath" 2>/dev/null; then
        err "容器内找不到脚本：$cpath"
        err "  宿主机文件：$(win_path "$f")"
        err "  请确认 docker-compose.yml 中已挂载  ../sql:/sql  并重建容器："
        err "    cd docker && docker-compose up -d --force-recreate hive-server"
        return 1
    fi

    log "执行 $base"

    # 执行并把输出写入日志文件
    docker exec "$HIVE_CONTAINER" \
        beeline -u "$HIVE_JDBC" --silent=true --force=true -f "$cpath" 2>&1 \
        | tee "$log_file"
    local rc=${PIPESTATUS[0]}

    # 双重判定：退出码 + 日志中的 Error
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
    # 用 stdin 重定向直接把脚本喂给容器内的 mysql，密码通过 MYSQL_PWD 环境变量传递
    # （不出现在命令行里）。
    # 【为什么这里用 stdin 是安全的】
    #   实测在 Git Bash（mintty 伪终端）下，`mysql < 文件` 这种「命令自身读 stdin」
    #   的形式工作正常；而 run_sql 里 `sh -c "cat > 文件" < 文件` 这种
    #   「多套一层 shell 再由 cat 读 stdin」的形式会拿到空内容 —— 两者行为不同。
    #   故此处保留 stdin 方式，避免为 mysql 容器也挂载一次 sql 目录。
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
