-- ============================================================================
-- 第 2 周 步骤 6：dwd_order_item 订单明细事实表清洗
-- ----------------------------------------------------------------------------
-- 文件 : sql/clean/10_clean_dwd_order_item.sql
-- 依赖 : 05_rebuild_dwd_tables.sql
--
-- 处理清单：
--   ① quantity ：0 / 负数 / >50 视为异常 → 置空并标记（实测 386 + 332 + 363）
--   ② item_amount ：按 quantity*unit_price*(1-discount) 计算，数量异常时置空
--
-- 【为什么数量上限取 50】
--   实测 quantity 最大 99，且 0/负数/>50 三类各约 350 条、分布均匀，
--   判断为随机植入的脏值。新零售场景单笔订单单品数量超过 50 件不合常理，
--   故以 [1, 50] 作为有效区间。
-- ============================================================================

USE ydsh_dwd;

INSERT OVERWRITE TABLE dwd_order_item
SELECT
    item_id,
    order_id,
    product_id,
    CASE WHEN quantity BETWEEN 1 AND 50 THEN quantity ELSE NULL END                    AS quantity,
    CASE WHEN quantity BETWEEN 1 AND 50 THEN 0 ELSE 1 END                              AS qty_is_fixed,
    unit_price,
    discount,
    CASE WHEN quantity BETWEEN 1 AND 50
         THEN round(quantity * unit_price * (1 - discount), 2)
         ELSE NULL END                                                                 AS item_amount
FROM ydsh_ods.ods_order_item;

-- 校验
SELECT 'dwd_order_item 行数' AS metric, CAST(count(*) AS STRING) AS val FROM dwd_order_item
UNION ALL SELECT 'quantity 被置空条数', CAST(sum(qty_is_fixed) AS STRING) FROM dwd_order_item
UNION ALL SELECT 'quantity 仍异常条数', CAST(sum(CASE WHEN quantity < 1 OR quantity > 50 THEN 1 ELSE 0 END) AS STRING) FROM dwd_order_item
UNION ALL SELECT 'item_amount 为空条数', CAST(sum(CASE WHEN item_amount IS NULL THEN 1 ELSE 0 END) AS STRING) FROM dwd_order_item;
