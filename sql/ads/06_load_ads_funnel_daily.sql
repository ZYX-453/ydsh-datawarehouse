-- =============================================================================
-- 文件   : sql/ads/06_load_ads_funnel_daily.sql
-- 作者   : 张宇翔
-- 阶段   : 第 3 周 · 子任务 1 —— ADS 行为漏斗 + 销售日报
-- -----------------------------------------------------------------------------
-- 一、行为漏斗（dwd_user_behavior）
--   层级顺序按业务转化路径固定为 浏览 → 收藏 → 加购 → 购买，
--   不按事件量排序，否则「购买 11,969 > 加购 8,286」会被排成倒漏斗，掩盖问题。
--   ⚠ 实测已知：模拟数据的行为是随机生成的，1,000 个用户全部四种行为都有，
--     因此用户级转化率恒为 100%，事件级转化率也不是单调递减。
--     这张表在本数据集下「结构正确但业务无解释力」，已在 docs/11_AI应用反思.md 中说明。
--     保留它的价值是：链路可用、口径正确，换成真实埋点数据即出结论。
--
-- 二、销售日报（dws_trade_day）
--   ma7 用 avg() OVER (ORDER BY ... ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)。
--     实测 avg()/lag() 的窗口在本镜像正常，只有 sum(double) OVER (ORDER BY ...) 返回 NULL。
--   weekday 用 pmod(datediff(stat_date,'2024-01-01'), 7) + 1，1=周一。
-- =============================================================================

INSERT OVERWRITE TABLE ydsh_ads.ads_behavior_funnel
SELECT
    s.step,
    s.behavior_type,
    s.event_cnt,
    s.user_cnt,
    s.event_cnt / pv.event_cnt          AS event_share
FROM (
    SELECT
        CASE behavior_type WHEN 'pv' THEN 1 WHEN 'fav' THEN 2
                           WHEN 'cart' THEN 3 WHEN 'buy' THEN 4 ELSE 9 END AS step,
        behavior_type,
        count(*)                    AS event_cnt,
        count(DISTINCT user_id)     AS user_cnt
    FROM ydsh_dwd.dwd_user_behavior
    GROUP BY behavior_type
) s
CROSS JOIN (
    SELECT count(*) AS event_cnt FROM ydsh_dwd.dwd_user_behavior WHERE behavior_type = 'pv'
) pv;

-- 二、销售日报（dwd_order 直接聚合，不经过 dws_trade_day）
--   为什么不复用 dws_trade_day：那张表按渠道拆开，同一天同一用户可能出现在多个渠道，
--   跨渠道去重后才能得到「当日成交用户数」，否则 sum(user_cnt) 会重复计数。
--   ma7 用 avg() OVER (ORDER BY ... ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)。
--     实测 avg()/lag() 的窗口在本镜像正常，只有 sum(double) OVER (ORDER BY ...) 返回 NULL。
--   weekday 用 pmod(datediff(stat_date,'2024-01-01'), 7) + 1，1=周一。
-- =============================================================================

INSERT OVERWRITE TABLE ydsh_ads.ads_behavior_funnel
SELECT
    s.step,
    s.behavior_type,
    s.event_cnt,
    s.user_cnt,
    s.event_cnt / pv.event_cnt          AS event_share
FROM (
    SELECT
        CASE behavior_type WHEN 'pv' THEN 1 WHEN 'fav' THEN 2
                           WHEN 'cart' THEN 3 WHEN 'buy' THEN 4 ELSE 9 END AS step,
        behavior_type,
        count(*)                    AS event_cnt,
        count(DISTINCT user_id)     AS user_cnt
    FROM ydsh_dwd.dwd_user_behavior
    GROUP BY behavior_type
) s
CROSS JOIN (
    SELECT count(*) AS event_cnt FROM ydsh_dwd.dwd_user_behavior WHERE behavior_type = 'pv'
) pv;

INSERT OVERWRITE TABLE ydsh_ads.ads_sales_daily
SELECT
    stat_date,
    gmv,
    order_cnt,
    user_cnt,
    gmv / order_cnt                                                     AS aov,
    avg(gmv) OVER (ORDER BY stat_date
                   ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)            AS ma7,
    pmod(datediff(stat_date, '2024-01-01'), 7) + 1                      AS weekday
FROM (
    SELECT
        order_date                  AS stat_date,
        sum(pay_amount)             AS gmv,
        count(DISTINCT order_id)    AS order_cnt,
        count(DISTINCT user_id)     AS user_cnt
    FROM ydsh_dwd.dwd_order
    WHERE is_gmv_included = 1
    GROUP BY order_date
) d;
