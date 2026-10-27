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
run_ods() {
    log "========== 阶段 1/2：ODS 贴源层 =========="
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
