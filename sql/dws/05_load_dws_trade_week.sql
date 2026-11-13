-- =============================================================================
-- 文件   : sql/dws/05_load_dws_trade_week.sql
-- 作者   : 张宇翔
-- 阶段   : 第 3 周 · 子任务 1 —— DWS 周×渠道汇总加载
-- -----------------------------------------------------------------------------
-- 口径：is_gmv_included = 1；aov = gmv / order_cnt（DOUBLE 裸除法，不 round）。
-- 周首日：date_sub(next_day(order_date,'MO'), 7)
--   实测验算：2024-01-01 是周一 → next_day('2024-01-01','MO') = 2024-01-08
--            再减 7 天 = 2024-01-01 ✓
--             2024-01-07 是周日 → next_day = 2024-01-08，减 7 = 2024-01-01 ✓
--   不用 date_format(x,'YYYY-ww')：该写法在 ISO 周与自然周之间、跨年周上都会错位。
-- 周表不分区：2024 全年只有 53 行 × 渠道数，分区只会制造小文件。
-- =============================================================================

INSERT OVERWRITE TABLE ydsh_dws.dws_trade_week
SELECT
    date_sub(next_day(order_date, 'MO'), 7)                  AS week_start,
    date_add(date_sub(next_day(order_date, 'MO'), 7), 6)     AS week_end,
    channel,
    sum(pay_amount)                                          AS gmv,
    count(DISTINCT order_id)                                 AS order_cnt,
    count(DISTINCT user_id)                                  AS user_cnt,
    sum(pay_amount) / count(DISTINCT order_id)               AS aov
FROM ydsh_dwd.dwd_order
WHERE is_gmv_included = 1
GROUP BY date_sub(next_day(order_date, 'MO'), 7),
         date_add(date_sub(next_day(order_date, 'MO'), 7), 6),
         channel;
