-- =============================================================================
-- 文件   : sql/ads/02_load_ads_kpi.sql
-- 作者   : 张宇翔
-- 阶段   : 第 3 周 · 子任务 1 —— ADS 核心 KPI（总览 + 月度趋势）
-- -----------------------------------------------------------------------------
-- 上游：dws_trade_day（月度 GMV）、dws_user_agg（累计口径校验）、dwd_order（复购明细）
-- 复购率口径：成交订单数 >= 2 的用户数 / 成交用户数。
--   注意不要用「订单数/用户数」的均值冒充复购率——两者量纲不同，会被平均成 9.99。
-- 环比：LAG(gmv) OVER (ORDER BY stat_ym)，首月无上月故为 NULL（不填 0，避免误读为「持平」）。
--   同比无法计算：本项目只有 2024 单年数据，缺少上年同期。
--   这一点在《预测建模分析报告》里作为「数据边界」明确写出，不用假数据凑指标。
-- 引擎注意：avg()/lag() 的窗口可用，但 sum(double) OVER (ORDER BY ...) 会返回 NULL，
--   本文件不依赖后者。
-- =============================================================================

-- ------------------------------------------------------ 1. 核心 KPI 总览 ----
-- 三个子查询 CROSS JOIN：
--   t = 交易侧（GMV / 订单 / 件数 / 优惠）
--   u = 用户侧（成交用户数，取 dws_user_agg 的 1,000 行）
--       —— 不用 sum(dws_trade_day.user_cnt)：跨渠道用户会被重复计数
--   r = 复购用户数
INSERT OVERWRITE TABLE ydsh_ads.ads_kpi_overview
SELECT
    '2024 全年（成交口径）'                            AS stat_scope,
    t.gmv,
    t.order_cnt,
    t.gmv / t.order_cnt                               AS aov,
    u.user_total                                      AS active_users,
    u.user_total                                      AS order_users,
    r.rep_users                                       AS repurchase_users,
    r.rep_users / u.user_total                        AS repurchase_rate,
    t.item_qty,
    t.discount_amt,
    t.discount_amt / (t.gmv + t.discount_amt)         AS discount_rate,
    t.gmv / 12                                        AS avg_month_gmv
FROM (
    SELECT
        sum(gmv)            AS gmv,
        sum(order_cnt)      AS order_cnt,
        sum(item_qty)       AS item_qty,
        sum(discount_amt)   AS discount_amt
    FROM ydsh_dws.dws_trade_day
) t
CROSS JOIN (
    SELECT count(*) AS user_total FROM ydsh_dws.dws_user_agg
) u
CROSS JOIN (
    SELECT count(*) AS rep_users FROM (
        SELECT user_id FROM ydsh_dwd.dwd_order
        WHERE is_gmv_included = 1
        GROUP BY user_id HAVING count(DISTINCT order_id) >= 2
    ) y
) r;

-- ------------------------------------------------------ 2. 月度 KPI 趋势 ----
DROP TABLE IF EXISTS stg_kpi_month;
CREATE TABLE stg_kpi_month STORED AS ORC AS
SELECT
    d.stat_ym,
    sum(d.gmv)                                    AS gmv,
    sum(d.order_cnt)                              AS order_cnt,
    count(DISTINCT d.stat_date)                   AS day_cnt,
    sum(d.gmv) / sum(d.order_cnt)                 AS aov
FROM ydsh_dws.dws_trade_day d
GROUP BY d.stat_ym;

-- 当月复购率：当月成交 >= 2 单用户 / 当月成交用户
DROP TABLE IF EXISTS stg_kpi_month_user;
CREATE TABLE stg_kpi_month_user STORED AS ORC AS
SELECT
    ym                                            AS stat_ym,
    count(*)                                      AS user_cnt,
    sum(CASE WHEN c >= 2 THEN 1 ELSE 0 END)       AS rep_users
FROM (
    SELECT user_id, substr(order_date, 1, 7) AS ym, count(DISTINCT order_id) AS c
    FROM ydsh_dwd.dwd_order
    WHERE is_gmv_included = 1
    GROUP BY user_id, substr(order_date, 1, 7)
) u
GROUP BY ym;

INSERT OVERWRITE TABLE ydsh_ads.ads_kpi_month
SELECT
    m.stat_ym,
    m.gmv,
    m.order_cnt,
    m.aov,
    u.user_cnt,
    u.rep_users / u.user_cnt                                        AS repurchase_rate,
    (m.gmv - LAG(m.gmv) OVER (ORDER BY m.stat_ym))
        / LAG(m.gmv) OVER (ORDER BY m.stat_ym)                      AS gmv_mom,
    (m.order_cnt - LAG(m.order_cnt) OVER (ORDER BY m.stat_ym))
        / LAG(m.order_cnt) OVER (ORDER BY m.stat_ym)                AS order_mom
FROM stg_kpi_month m
LEFT JOIN stg_kpi_month_user u
       ON m.stat_ym = u.stat_ym;

DROP TABLE IF EXISTS stg_kpi_month;
DROP TABLE IF EXISTS stg_kpi_month_user;
