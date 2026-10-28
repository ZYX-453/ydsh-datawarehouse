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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] $*${NC}"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] $*${NC}"; }

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
    local base
    base="$(basename "$f")"

    if [ ! -f "$f" ]; then
        err "文件不存在：$f"; return 1
    fi

    log "执行 $base"
    docker cp "$f" "$HIVE_CONTAINER:/tmp/$base" >/dev/null 2>&1
    docker exec "$HIVE_CONTAINER" \
        beeline -u "$HIVE_JDBC" --silent=true --force=true -f "/tmp/$base"
    local rc=$?

    if [ $rc -ne 0 ]; then
        err "$base 执行返回非零退出码：$rc"
        return $rc
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
    docker cp "$f" "$MYSQL_CONTAINER:/tmp/fix_charset.sql" >/dev/null 2>&1
    if docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$MYSQL_CONTAINER" \
            mysql -uroot < "$f" >/dev/null 2>&1; then
        log "字符集修复完成"
    else
        warn "字符集修复失败（不影响数据，仅影响注释显示）"
    fi
}

run_ods() {
    log "========== 阶段 1/2：ODS 贴源层 =========="
    fix_charset
    run_sql "$SCRIPT_DIR/sql/ods/01_create_database.sql"
    run_sql "$SCRIPT_DIR/sql/ods/02_create_ods_tables.sql"
    run_sql "$SCRIPT_DIR/sql/ods/03_load_ods_data.sql"
    run_sql "$SCRIPT_DIR/sql/quality/01_quality_assessment.sql"
}

run_clean() {
    log "========== 阶段 2/2：DWD 明细层与数据清洗 =========="
    run_sql "$SCRIPT_DIR/sql/clean/01_create_dwd_tables.sql"
    run_sql "$SCRIPT_DIR/sql/clean/02_handle_missing_values.sql"
    run_sql "$SCRIPT_DIR/sql/clean/03_deduplicate_orders.sql"
    run_sql "$SCRIPT_DIR/sql/clean/04_cleaning_summary.sql"
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
