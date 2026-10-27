-- ============================================================================
-- 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统
-- 数据清洗（一）：重复值检测与去重
-- ----------------------------------------------------------------------------
-- 文件    : sql/clean/03_deduplicate_orders.sql
-- 作者    : 张宇翔
-- 依赖    : 01_create_dwd_tables.sql 已执行
-- 执行    : beeline -u jdbc:hive2://localhost:10000 -f 03_deduplicate_orders.sql
--
-- 【去重策略说明】
--   ods_order 的 600 行重复分为两类，语义完全不同，必须区别对待：
--     ① 整行完全重复（所有字段取值一致）→ 属采集/同步环节的重复写入，直接去重保留 1 条
--     ② 主键重复但字段有差异 → 属业务侧多次修改未做版本管理，需按业务规则取舍
--   两类统一用 ROW_NUMBER() 处理，差异体现在「排序规则」上：
--     时间最新优先（后写入的通常为修正后的值），时间相同则金额较大者优先，
--     确保不因去重丢失有效金额信息。
-- ============================================================================

USE ydsh_dwd;

-- ############################################################################
-- 第一步：重复值检测（清洗前留证）
-- ############################################################################

-- 1.1 总体重复情况
SELECT
    COUNT(*)                                                AS total_rows,
    COUNT(DISTINCT order_id)                                AS distinct_orders,
    COUNT(*) - COUNT(DISTINCT order_id)                     AS duplicate_rows,
    ROUND((COUNT(*) - COUNT(DISTINCT order_id)) * 100.0 / COUNT(*), 2) AS dup_rate_pct
FROM ydsh_ods.ods_order;

-- 1.2 重复组数明细（group by + having count(*)>1，与手册步骤 7 要求一致）
SELECT
    COUNT(*)      AS dup_group_cnt,
    SUM(cnt)      AS rows_in_dup_groups,
    SUM(cnt) - COUNT(*) AS extra_rows,
    MAX(cnt)      AS max_row_per_order
FROM (
    SELECT order_id, COUNT(*) AS cnt
    FROM ydsh_ods.ods_order
    GROUP BY order_id
    HAVING COUNT(*) > 1
) t;

-- 1.3 区分两类重复：
--     full_dup_groups    = 组内所有行完全相同（整行完全重复）
--     partial_dup_groups = 组内存在字段差异（主键重复但内容不同）
SELECT
    SUM(CASE WHEN variant_cnt = 1 THEN 1 ELSE 0 END) AS full_dup_groups,
    SUM(CASE WHEN variant_cnt > 1 THEN 1 ELSE 0 END) AS partial_dup_groups
FROM (
    SELECT order_id,
           COUNT(DISTINCT CONCAT_WS('|', user_id, store_id, order_date, order_time,
                                    CAST(pay_amount AS STRING), CAST(discount_amount AS STRING),
                                    pay_type, order_status, channel)) AS variant_cnt
    FROM ydsh_ods.ods_order
    GROUP BY order_id
    HAVING COUNT(*) > 1
) t;

-- 1.4 主键重复但内容不同的样本（人工确认差异在哪一列，用于报告举证）
SELECT order_id, user_id, store_id, order_date, order_time,
       pay_amount, discount_amount, pay_type, order_status, channel
FROM ydsh_ods.ods_order
WHERE order_id IN (
    SELECT order_id FROM (
        SELECT order_id,
               COUNT(DISTINCT CONCAT_WS('|', user_id, store_id, order_date, order_time,
                                        CAST(pay_amount AS STRING), CAST(discount_amount AS STRING),
                                        pay_type, order_status, channel)) AS vc
        FROM ydsh_ods.ods_order
        GROUP BY order_id
        HAVING COUNT(*) > 1
    ) x WHERE vc > 1
)
ORDER BY order_id, order_time
LIMIT 20;

-- ############################################################################
-- 第二步：执行去重
-- ############################################################################

-- 排序规则说明：
--   order_date 源格式为 'yyyy/M/d'（斜杠且月日不补零，如 2024/7/26），
--   直接用字符串排序会得到错误结果（'2024/12/6' 会排在 '2024/7/26' 之前）。
--   故先拼接为完整时间串再用 'yyyy/M/d HH:mm:ss' 格式解析为 unix 时间戳后排序。
--   解析失败（理论不会发生）时 COALESCE 兜底为 0，退化为按金额排序。
--
--   同时用窗口函数 COUNT(*) OVER (PARTITION BY order_id) 把「该订单在 ODS 中出现几次」
--   写入 ods_dup_cnt 字段，保留重复程度的可追溯性，便于后续统计与报告引用。

INSERT OVERWRITE TABLE dwd_order
SELECT
    order_id,
    user_id,
    store_id,
    order_date,
    order_time,
    pay_amount,
    discount_amount,
    pay_type,
    order_status,
    channel,
    ods_dup_cnt
FROM (
    SELECT
        order_id, user_id, store_id, order_date, order_time,
        pay_amount, discount_amount, pay_type, order_status, channel,
        ods_dup_cnt,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY
                COALESCE(unix_timestamp(CONCAT(order_date, ' ', order_time), 'yyyy/M/d HH:mm:ss'), 0) DESC,
                pay_amount      DESC,
                discount_amount DESC
        ) AS rn
    FROM (
        SELECT
            order_id, user_id, store_id, order_date, order_time,
            pay_amount, discount_amount, pay_type, order_status, channel,
            COUNT(*) OVER (PARTITION BY order_id) AS ods_dup_cnt
        FROM ydsh_ods.ods_order
    ) with_cnt
) ranked
WHERE rn = 1;

-- ############################################################################
-- 第三步：去重效果验证
-- ############################################################################

-- 3.1 去重后：主键唯一、行数与预期一致（预期 15,000）
SELECT
    COUNT(*)                            AS total_rows,
    COUNT(DISTINCT order_id)            AS distinct_orders,
    COUNT(*) - COUNT(DISTINCT order_id) AS still_dup
FROM dwd_order;

-- 3.2 去重前后行数差异
--     用 SUM(ods_dup_cnt) 还原「去重前总行数」，与 COUNT(*) 相减即为删除行数。
--     该写法不依赖标量子查询（Hive 不支持 SELECT 列表中的标量子查询）。
--     一致性要求：SUM(ods_dup_cnt) 应等于 ODS 行数；差额应等于第一步的 extra_rows（600）。
SELECT 'ODS 订单表行数（去重前）'          AS metric, COUNT(*)                  AS val FROM ydsh_ods.ods_order
UNION ALL SELECT 'DWD 订单表行数（去重后）',          COUNT(*)                  FROM dwd_order
UNION ALL SELECT 'ods_dup_cnt 合计（应=去重前行数）', SUM(ods_dup_cnt)          FROM dwd_order
UNION ALL SELECT '删除的重复行数（应=600）',          SUM(ods_dup_cnt) - COUNT(*) FROM dwd_order;

-- 3.3 【关键】去重未误删有明细的订单
--     去重只应删除重复行，不应让任何订单失去订单主记录。
--     预期：orphan_in_order = 0（明细引用的订单在 dwd_order 中都能找到）
SELECT
    COUNT(*) AS item_rows_total,
    SUM(CASE WHEN o.order_id IS NULL THEN 1 ELSE 0 END) AS orphan_item_rows
FROM ydsh_ods.ods_order_item i
LEFT JOIN dwd_order o ON i.order_id = o.order_id;

-- 3.4 曾重复的订单数量应等于重复组数（预期 586 组）
SELECT
    SUM(CASE WHEN ods_dup_cnt > 1 THEN 1 ELSE 0 END) AS orders_once_duplicated,
    MAX(ods_dup_cnt)                                 AS max_dup_cnt,
    SUM(CASE WHEN ods_dup_cnt = 1 THEN 1 ELSE 0 END) AS orders_always_unique
FROM dwd_order;

-- 3.5 去重结果抽样：查看曾重复订单最终保留了哪一条
SELECT order_id, order_date, order_time, pay_amount, ods_dup_cnt
FROM dwd_order
WHERE ods_dup_cnt > 1
ORDER BY ods_dup_cnt DESC, order_id
LIMIT 10;
