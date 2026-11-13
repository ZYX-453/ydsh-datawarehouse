-- =============================================================================
-- 文件   : sql/dws/03_load_dws_store_month.sql
-- 作者   : 张宇翔
-- 阶段   : 第 3 周 · 子任务 1 —— DWS 月×门店汇总加载
-- -----------------------------------------------------------------------------
-- 口径：GMV / 订单数 / 用户数 均取 is_gmv_included = 1。
--       aov = gmv / order_cnt，DOUBLE 裸除法，不做 round（写入 ORC 会变 NULL）。
-- 关联：LEFT JOIN dim_store，门店维度缺失时仍保留交易行，避免数据静默丢失。
-- =============================================================================

SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;

INSERT OVERWRITE TABLE ydsh_dws.dws_store_month PARTITION (stat_ym)
SELECT
    o.store_id,
    s.store_name,
    s.province,
    s.city,
    sum(o.pay_amount)                                   AS gmv,
    count(DISTINCT o.order_id)                          AS order_cnt,
    count(DISTINCT o.user_id)                           AS user_cnt,
    sum(o.pay_amount) / count(DISTINCT o.order_id)      AS aov,
    substr(o.order_date, 1, 7)                          AS stat_ym
FROM ydsh_dwd.dwd_order o
LEFT JOIN ydsh_dwd.dim_store s
       ON o.store_id = s.store_id
WHERE o.is_gmv_included = 1
GROUP BY o.store_id, s.store_name, s.province, s.city, substr(o.order_date, 1, 7);
