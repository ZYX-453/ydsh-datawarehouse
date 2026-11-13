-- =============================================================================
-- 文件   : sql/dws/04_load_dws_product_month.sql
-- 作者   : 张宇翔
-- 阶段   : 第 3 周 · 子任务 1 —— DWS 月 × 商品汇总加载
-- -----------------------------------------------------------------------------
-- 关联链：dwd_order_item → dwd_order（取日期与 GMV 口径）→ dim_product（品类/品牌/成本）
--   注意：商品维度只能挂在订单明细上，dwd_order 没有 product_id / quantity 字段。
--   部署手册步骤 1 的 `dwd_order o join dim_product p on o.product_id = p.product_id`
--   照抄会直接报 Error 10004: Invalid column reference（第 2 周已实测确认）。
--
-- ⚠ 口径决策（本周最重要的一个判断，详见 docs/09_指标口径与ADS设计.md 第 2 节）
--   实测发现源数据「订单实付」与「明细金额」不自洽：
--     订单 O2024000001  实付 4,374.46  单价合计 14,827.84  明细金额合计 52,836.35
--     全量对比：订单实付合计 24,717,464.96，明细金额合计 266,208,760.41（10.8 倍）
--   三种可能的口径中只能选一个当真值：
--     (a) 直接 sum(item_amount)            → 品类销售额合计 2.66 亿，与 GMV 差 10.8 倍，
--                                            同一份报表里出现两套口径，不可接受
--     (b) 直接 sum(o.pay_amount) group by   → 手册写法。一个订单含多个品类时，
--         p.category                          订单金额被每个品类各计一次，实测虚增 2.5 倍
--     (c) 订单实付按明细金额占比分摊        ← 采用
--         allocated = pay_amount * item_amount / 该订单明细金额合计
--         性质：品类销售额合计恒等于 GMV，可加总、可算占比、可复核
--   为什么选 (c)：GMV 是唯一锚点（合同口径以实付为准），明细金额是「吊牌价口径」，
--   只能用来表达结构（品类占比、件数、毛利方向），不能直接当销售额。分摊法把
--   订单级优惠/差异按比例下推到行级，是零售数仓处理「订单金额 ≠ 行金额」的标准做法。
-- =============================================================================

SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;

-- 第一段：算出每笔订单的分摊权重合计，作为分摊基数
--   用临时表而非窗口函数，原因是本镜像 sum(double) OVER (PARTITION BY) 虽可用，
--   但一旦叠加 ORDER BY 就返回 NULL（第 2 周已踩），临时表没有这个风险。
--
--   兜底权重：实测 736 行 item_amount 为 NULL、529 行为 0/负（均源于数量被置空），
--   若直接按 item_amount 分摊，会有 130 笔订单（占 GMV 1.25%）完全无法归因。
--   故权重取 w = CASE WHEN item_amount > 0 THEN item_amount ELSE 1 END，
--   即「金额有效按金额加权，金额缺失按平权行数」，保证有明细的订单 100% 可分摊，
--   且金额有效的行仍保持原有比例结构。
DROP TABLE IF EXISTS stg_order_item_base;
CREATE TABLE stg_order_item_base STORED AS ORC AS
SELECT
    i.order_id,
    i.product_id,
    i.quantity,
    i.item_amount,
    CASE WHEN i.item_amount IS NOT NULL AND i.item_amount > 0
         THEN i.item_amount ELSE 1.0 END AS alloc_w,
    o.pay_amount,
    o.order_date
FROM ydsh_dwd.dwd_order_item i
JOIN ydsh_dwd.dwd_order o
  ON i.order_id = o.order_id
WHERE o.is_gmv_included = 1;

DROP TABLE IF EXISTS stg_order_amount;
CREATE TABLE stg_order_amount STORED AS ORC AS
SELECT order_id, sum(alloc_w) AS ord_item_sum
FROM stg_order_item_base
GROUP BY order_id;

-- 第二段：按明细占比分摊订单实付，再按 月 × 商品 聚合
INSERT OVERWRITE TABLE ydsh_dws.dws_product_month PARTITION (stat_ym)
SELECT
    b.product_id,
    p.product_name,
    p.category,
    p.sub_category,
    p.brand,
    sum(b.quantity)                                                 AS qty,
    sum(b.pay_amount * b.alloc_w / a.ord_item_sum)                  AS sales_amt,
    count(DISTINCT b.order_id)                                      AS order_cnt,
    sum(b.quantity * p.cost)                                        AS cost_amt,
    substr(b.order_date, 1, 7)                                      AS stat_ym
FROM stg_order_item_base b
JOIN stg_order_amount a
  ON b.order_id = a.order_id
LEFT JOIN ydsh_dwd.dim_product p
  ON b.product_id = p.product_id
GROUP BY b.product_id, p.product_name, p.category, p.sub_category, p.brand,
         substr(b.order_date, 1, 7);

DROP TABLE IF EXISTS stg_order_item_base;
DROP TABLE IF EXISTS stg_order_amount;
