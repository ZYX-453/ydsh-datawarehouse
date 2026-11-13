-- =============================================================================
-- 文件   : sql/dws/06_load_dws_user_agg.sql
-- 作者   : 张宇翔
-- 阶段   : 第 3 周 · 子任务 1 —— DWS 用户全周期聚合（RFM 原始值）
-- -----------------------------------------------------------------------------
-- 粒度：user_id（全生命周期，不分区）。
-- 口径：只统计 is_gmv_included = 1 的订单——「成交用户」而不是「下单用户」。
--   R 值 = 观测截止日 2024-12-31 与该用户末单日期的天数差（越小越活跃）。
--   F 值 = 成交订单数；M 值 = 累计成交金额。
--   RFM 打分与分层在 ADS 层做（08_ads_user_value.sql），DWS 只存原始值，
--   避免在汇总层写死分位规则后无法回溯。
-- 注意：
--   dim_user 主键 user_id 唯一（第 2 周已修），JOIN 不会放大行数。
--   active_months 用 count(DISTINCT substr(order_date,1,7))，
--   与「末单-首单月数差」不同：后者会把无消费月份也算作活跃，口径偏松。
-- =============================================================================

INSERT OVERWRITE TABLE ydsh_dws.dws_user_agg
SELECT
    o.user_id,
    u.user_name,
    u.member_level,
    u.province,
    u.city,
    min(o.order_date)                                        AS first_order_date,
    max(o.order_date)                                        AS last_order_date,
    count(DISTINCT o.order_id)                               AS order_cnt,
    sum(o.pay_amount)                                        AS total_gmv,
    sum(o.pay_amount) / count(DISTINCT o.order_id)           AS avg_order_amt,
    count(DISTINCT substr(o.order_date, 1, 7))               AS active_months,
    datediff('2024-12-31', max(o.order_date))                AS r_value,
    count(DISTINCT o.order_id)                               AS f_value,
    sum(o.pay_amount)                                        AS m_value
FROM ydsh_dwd.dwd_order o
LEFT JOIN ydsh_dwd.dim_user u
       ON o.user_id = u.user_id
WHERE o.is_gmv_included = 1
GROUP BY o.user_id, u.user_name, u.member_level, u.province, u.city;
