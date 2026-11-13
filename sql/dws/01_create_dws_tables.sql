-- =============================================================================
-- 文件   : sql/dws/01_create_dws_tables.sql
-- 作者   : 张宇翔
-- 阶段   : 第 3 周 · 子任务 1 —— DWS 汇总层建表
-- 上游   : ydsh_dwd（只依赖 DWD，禁止跨层读 ODS）
-- -----------------------------------------------------------------------------
-- 设计原则：
--   1) 粒度：DWS 只做「轻度汇总」，粒度必须能被下游 ADS 再聚合，不能提前丢失维度。
--      - dws_trade_day      : 日 × 渠道
--      - dws_store_month    : 月 × 门店
--      - dws_product_month  : 月 × 商品
--      - dws_user_agg       : 用户（全生命周期，不分区）
--   2) 口径：所有金额类指标统一取 is_gmv_included = 1 的订单，
--      即「已完成 + 已支付」，不含待支付 / 已取消 / 退款中。
--      实测若不筛该条件，GMV 会从 2,471.7 万虚增到约 3,700 万（高估约 50%）。
--   3) 分区：交易类按 stat_ym（年月）分区，与 DWD 的 order_ym 对齐，
--      便于分区裁剪；用户表是快照性质，不分区。
--   4) 存储：ORC + SNAPPY，与 DWD 保持一致。
--   5) 粒度覆盖：任务书要求「按天 / 周 / 月、品类、门店、渠道」五类汇总，
--      对应关系为 日×渠道（dws_trade_day）/ 周×渠道（dws_trade_week）/
--      月×门店（dws_store_month）/ 月×商品（dws_product_month，品类可由商品聚合）/
--      用户全周期（dws_user_agg）。
-- =============================================================================

USE ydsh_dws;

-- ---------------------------------------------------------------- 周×渠道交易 ----
-- 粒度：自然周（周一为周首日）× 渠道。
-- 周首日算法：date_sub(next_day(order_date,'MO'), 7)，
--   比 date_format(...,'YYYY-ww') 可靠——后者在不同 locale 下周起始日不一致。
DROP TABLE IF EXISTS dws_trade_week;
CREATE TABLE dws_trade_week (
    week_start      STRING  COMMENT '周首日 yyyy-MM-dd（周一）',
    week_end        STRING  COMMENT '周末日 yyyy-MM-dd（周日）',
    channel         STRING  COMMENT '下单渠道',
    gmv             DOUBLE  COMMENT '成交金额',
    order_cnt       BIGINT  COMMENT '成交订单数',
    user_cnt        BIGINT  COMMENT '成交用户数',
    aov             DOUBLE  COMMENT '客单价 = gmv / order_cnt'
)
COMMENT 'DWS 交易主题：周 × 渠道 轻度汇总'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ---------------------------------------------------------------- 日×渠道交易 ----
DROP TABLE IF EXISTS dws_trade_day;
CREATE TABLE dws_trade_day (
    stat_date       STRING  COMMENT '统计日期 yyyy-MM-dd',
    channel         STRING  COMMENT '下单渠道（已标准化）',
    gmv             DOUBLE  COMMENT '成交金额（is_gmv_included=1 的实付金额之和）',
    order_cnt       BIGINT  COMMENT '成交订单数（去重）',
    user_cnt        BIGINT  COMMENT '成交用户数（去重）',
    discount_amt    DOUBLE  COMMENT '优惠金额合计',
    item_qty        BIGINT  COMMENT '成交商品件数（来自订单明细）'
)
COMMENT 'DWS 交易主题：日 × 渠道 轻度汇总'
PARTITIONED BY (stat_ym STRING COMMENT '统计年月 yyyy-MM')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ---------------------------------------------------------------- 月×门店交易 ----
DROP TABLE IF EXISTS dws_store_month;
CREATE TABLE dws_store_month (
    store_id        STRING  COMMENT '门店编号',
    store_name      STRING  COMMENT '门店名称',
    province        STRING  COMMENT '省份',
    city            STRING  COMMENT '城市',
    gmv             DOUBLE  COMMENT '成交金额',
    order_cnt       BIGINT  COMMENT '成交订单数',
    user_cnt        BIGINT  COMMENT '成交用户数',
    aov             DOUBLE  COMMENT '客单价 = gmv / order_cnt'
)
COMMENT 'DWS 交易主题：月 × 门店 轻度汇总'
PARTITIONED BY (stat_ym STRING COMMENT '统计年月 yyyy-MM')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ---------------------------------------------------------------- 月×商品销售 ----
DROP TABLE IF EXISTS dws_product_month;
CREATE TABLE dws_product_month (
    product_id      STRING  COMMENT '商品编号',
    product_name    STRING  COMMENT '商品名称',
    category        STRING  COMMENT '一级类目',
    sub_category    STRING  COMMENT '二级类目',
    brand           STRING  COMMENT '品牌',
    qty             BIGINT  COMMENT '销售件数',
    sales_amt       DOUBLE  COMMENT '销售额（明细金额之和）',
    order_cnt       BIGINT  COMMENT '涉及订单数（去重）',
    cost_amt        DOUBLE  COMMENT '成本额 = 件数 × 成本价（用于毛利测算）'
)
COMMENT 'DWS 商品主题：月 × 商品 轻度汇总'
PARTITIONED BY (stat_ym STRING  COMMENT '统计年月 yyyy-MM')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ---------------------------------------------------------------- 用户全周期 ----
DROP TABLE IF EXISTS dws_user_agg;
CREATE TABLE dws_user_agg (
    user_id         STRING  COMMENT '用户编号',
    user_name       STRING  COMMENT '用户姓名',
    member_level    STRING  COMMENT '会员等级（中文标准值）',
    province        STRING  COMMENT '省份',
    city            STRING  COMMENT '城市',
    first_order_date STRING COMMENT '首单日期 yyyy-MM-dd',
    last_order_date  STRING COMMENT '末单日期 yyyy-MM-dd',
    order_cnt       BIGINT  COMMENT '成交订单数',
    total_gmv       DOUBLE  COMMENT '累计成交金额',
    avg_order_amt   DOUBLE  COMMENT '笔单价 = total_gmv / order_cnt',
    active_months   BIGINT  COMMENT '有成交的月份数（活跃月数）',
    r_value         INT     COMMENT 'R 分位：末单距 2024-12-31 的天数',
    f_value         BIGINT  COMMENT 'F 值：成交订单数',
    m_value         DOUBLE  COMMENT 'M 值：累计成交金额'
)
COMMENT 'DWS 用户主题：用户全生命周期聚合（RFM 原始值）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');
