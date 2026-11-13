-- =============================================================================
-- 文件   : sql/dws/02_load_dws_trade_day.sql
-- 作者   : 张宇翔
-- 阶段   : 第 3 周 · 子任务 1 —— DWS 日×渠道汇总加载
-- -----------------------------------------------------------------------------
-- 口径：
--   GMV / 订单数 / 用户数 均只统计 is_gmv_included = 1（已完成 + 已支付）。
--   item_qty 需要关联订单明细，若与主指标写在同一个 SELECT 里，
--   JOIN 会按明细行放大订单行，导致 GMV 被重复累加（第 2 周已踩过同类坑）。
--   因此拆成「订单侧聚合」与「明细侧聚合」两个子查询，再按 (日期, 渠道) 关联。
-- 引擎注意：
--   目标表 gmv / discount_amt 为 DOUBLE，落表一律用裸表达式；
--   round(double, n) 与 cast(... as decimal) 出现在 INSERT 的 SELECT 中会写 NULL。
-- =============================================================================

SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;

INSERT OVERWRITE TABLE ydsh_dws.dws_trade_day PARTITION (stat_ym)
SELECT
    t.stat_date,
    t.channel,
    t.gmv,
    t.order_cnt,
    t.user_cnt,
    t.discount_amt,
    COALESCE(q.item_qty, 0) AS item_qty,
    t.stat_ym
FROM (
    SELECT
        order_date                          AS stat_date,
        channel,
        sum(pay_amount)                     AS gmv,
        count(DISTINCT order_id)            AS order_cnt,
        count(DISTINCT user_id)             AS user_cnt,
        sum(discount_amount)                AS discount_amt,
        substr(order_date, 1, 7)            AS stat_ym
    FROM ydsh_dwd.dwd_order
    WHERE is_gmv_included = 1
    GROUP BY order_date, channel, substr(order_date, 1, 7)
) t
LEFT JOIN (
    SELECT
        o.order_date            AS stat_date,
        o.channel,
        sum(i.quantity)         AS item_qty
    FROM ydsh_dwd.dwd_order o
    JOIN ydsh_dwd.dwd_order_item i
      ON o.order_id = i.order_id
    WHERE o.is_gmv_included = 1
    GROUP BY o.order_date, o.channel
) q
  ON t.stat_date = q.stat_date
 AND t.channel   = q.channel;
