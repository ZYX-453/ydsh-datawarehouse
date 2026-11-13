-- =============================================================================
-- 文件   : sql/ads/01_create_ads_tables.sql
-- 作者   : 张宇翔
-- 阶段   : 第 3 周 · 子任务 1 —— ADS 应用层建表
-- -----------------------------------------------------------------------------
-- 定位：ADS 是「面向业务场景」的输出层，允许冗余、允许固化口径，
--       每张表对应一个具体的消费场景（日报 / TopN / 分层 / 漏斗），
--       下游 BI 或 NL2SQL 直接查 ADS，不再做二次聚合。
-- 与 DWS 的区别：
--   DWS 保证「可再聚合」，所以保留维度、不写死占比；
--   ADS 允许「不可再聚合」，占比、排名、分层标签都在这一层算好。
-- 口径统一（全层一致，详见 docs/09_指标口径与ADS设计.md）：
--   GMV      = sum(pay_amount) WHERE is_gmv_included = 1
--   订单量   = count(DISTINCT order_id) 同上
--   客单价   = GMV / 订单量
--   活跃用户 = count(DISTINCT user_id) 同上（成交口径，非登录口径）
--   复购率   = 成交 ≥2 单的用户数 / 成交用户数
-- 引擎注意：所有 DOUBLE 字段落表用裸表达式，禁止 round()/cast(decimal)（写 ORC 变 NULL）。
-- =============================================================================

USE ydsh_ads;

-- ------------------------------------------------------------- 1. 核心 KPI 总览 ----
DROP TABLE IF EXISTS ads_kpi_overview;
CREATE TABLE ads_kpi_overview (
    stat_scope      STRING COMMENT '统计口径范围，如 2024 全年',
    gmv             DOUBLE COMMENT 'GMV 成交总额',
    order_cnt       BIGINT COMMENT '订单量（去重）',
    aov             DOUBLE COMMENT '客单价 = gmv / order_cnt',
    active_users    BIGINT COMMENT '活跃（成交）用户数',
    order_users     BIGINT COMMENT '下单用户数（与活跃用户同口径，用于复购率分母）',
    repurchase_users BIGINT COMMENT '复购用户数（成交 >= 2 单）',
    repurchase_rate DOUBLE COMMENT '复购率 = 复购用户 / 下单用户',
    item_qty        BIGINT COMMENT '成交件数',
    discount_amt    DOUBLE COMMENT '优惠金额合计',
    discount_rate   DOUBLE COMMENT '优惠率 = 优惠金额 / (GMV + 优惠金额)',
    avg_month_gmv   DOUBLE COMMENT '月均 GMV'
)
COMMENT 'ADS 应用层：企业核心 KPI 总览（单行）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ------------------------------------------------------------- 2. 月度 KPI 趋势 ----
DROP TABLE IF EXISTS ads_kpi_month;
CREATE TABLE ads_kpi_month (
    stat_ym         STRING COMMENT '统计年月 yyyy-MM',
    gmv             DOUBLE COMMENT 'GMV',
    order_cnt       BIGINT COMMENT '订单量',
    aov             DOUBLE COMMENT '客单价',
    user_cnt        BIGINT COMMENT '成交用户数',
    repurchase_rate DOUBLE COMMENT '当月复购率 = 当月成交 >=2 单用户 / 当月成交用户',
    gmv_mom         DOUBLE COMMENT 'GMV 环比 = (本月 - 上月) / 上月',
    order_mom       DOUBLE COMMENT '订单量环比'
)
COMMENT 'ADS 应用层：月度 KPI 与环比'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- --------------------------------------------------------- 3. 品类销售 TopN ----
DROP TABLE IF EXISTS ads_category_rank;
CREATE TABLE ads_category_rank (
    rk              INT    COMMENT '销售额排名',
    category        STRING COMMENT '一级类目',
    sales_amt       DOUBLE COMMENT '销售额（订单实付按明细占比分摊后归集）',
    sales_share     DOUBLE COMMENT '销售额占比',
    order_cnt       BIGINT COMMENT '涉及订单数',
    qty             BIGINT COMMENT '销售件数',
    aov             DOUBLE COMMENT '笔单价 = sales_amt / order_cnt',
    brand_cnt       BIGINT COMMENT '在售品牌数'
)
COMMENT 'ADS 应用层：品类销售排名与占比'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- --------------------------------------------------------- 4. 省份销售排名 ----
DROP TABLE IF EXISTS ads_region_rank;
CREATE TABLE ads_region_rank (
    rk              INT    COMMENT 'GMV 排名',
    province        STRING COMMENT '省份',
    gmv             DOUBLE COMMENT 'GMV',
    gmv_share       DOUBLE COMMENT 'GMV 占比',
    order_cnt       BIGINT COMMENT '订单量',
    user_cnt        BIGINT COMMENT '成交用户数',
    store_cnt       BIGINT COMMENT '门店数',
    aov             DOUBLE COMMENT '客单价'
)
COMMENT 'ADS 应用层：省份销售排名'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- --------------------------------------------------------- 5. 门店销售 TopN ----
DROP TABLE IF EXISTS ads_store_top10;
CREATE TABLE ads_store_top10 (
    rk              INT    COMMENT 'GMV 排名',
    store_id        STRING COMMENT '门店编号',
    store_name      STRING COMMENT '门店名称',
    province        STRING COMMENT '省份',
    city            STRING COMMENT '城市',
    gmv             DOUBLE COMMENT 'GMV',
    order_cnt       BIGINT COMMENT '订单量',
    aov             DOUBLE COMMENT '客单价'
)
COMMENT 'ADS 应用层：门店销售 Top10'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- --------------------------------------------------------- 6. 用户价值分层 ----
DROP TABLE IF EXISTS ads_user_value;
CREATE TABLE ads_user_value (
    segment         STRING COMMENT 'RFM 客户分层名称',
    user_cnt        BIGINT COMMENT '用户数',
    user_share      DOUBLE COMMENT '用户占比',
    gmv             DOUBLE COMMENT '该层 GMV',
    gmv_share       DOUBLE COMMENT 'GMV 占比',
    avg_gmv         DOUBLE COMMENT '人均消费',
    avg_orders      DOUBLE COMMENT '人均订单数',
    avg_recency     DOUBLE COMMENT '平均 R 值（末单距 2024-12-31 天数）'
)
COMMENT 'ADS 应用层：用户价值分层（RFM）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- --------------------------------------------------------- 7. 行为漏斗 ----
DROP TABLE IF EXISTS ads_behavior_funnel;
CREATE TABLE ads_behavior_funnel (
    step            INT    COMMENT '漏斗层级 1=浏览 2=收藏 3=加购 4=购买',
    behavior_type   STRING COMMENT '行为类型 pv/fav/cart/buy',
    event_cnt       BIGINT COMMENT '行为事件数',
    user_cnt        BIGINT COMMENT '涉及用户数',
    event_share     DOUBLE COMMENT '事件占比（相对浏览）'
)
COMMENT 'ADS 应用层：用户行为漏斗'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- --------------------------------------------------------- 8. 销售日报 ----
DROP TABLE IF EXISTS ads_sales_daily;
CREATE TABLE ads_sales_daily (
    stat_date       STRING COMMENT '日期 yyyy-MM-dd',
    gmv             DOUBLE COMMENT '当日 GMV',
    order_cnt       BIGINT COMMENT '当日订单量',
    user_cnt        BIGINT COMMENT '当日成交用户数',
    aov             DOUBLE COMMENT '当日客单价',
    ma7             DOUBLE COMMENT '7 日移动平均 GMV（不足 7 天取已有天数）',
    weekday         INT    COMMENT '星期几 1=周一 ... 7=周日'
)
COMMENT 'ADS 应用层：销售日报（供预测建模与可视化）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');
