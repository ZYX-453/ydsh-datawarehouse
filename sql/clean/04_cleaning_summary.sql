-- ============================================================================
-- 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统
-- 数据清洗效果汇总（清洗前后对比）
-- ----------------------------------------------------------------------------
-- 文件    : sql/clean/04_cleaning_summary.sql
-- 作者    : 张宇翔
-- 依赖    : 02_handle_missing_values.sql、03_deduplicate_orders.sql 已执行
-- 执行    : beeline -u jdbc:hive2://localhost:10000 -f 04_cleaning_summary.sql
--
-- 用途：一次性输出第 1 周全部清洗成果的量化对比，
--       结果直接填入《数据质量预评估表》的「清洗前后对比」章节与答辩 PPT。
--
-- 【写法约束】Hive 不支持在 SELECT 列表中书写标量子查询（如 (SELECT COUNT(*) FROM t)），
--   因此所有「横向对比」统一改为「纵向 UNION ALL 展开」：每行一个指标，
--   用 layer 字段区分清洗前（ODS）/ 清洗后（DWD）。这是 Hive 场景下最稳妥的对比写法。
-- ============================================================================

USE ydsh_dwd;

-- ############################################################################
-- 一、各表清洗前后行数对比
-- ############################################################################
SELECT '用户表'   AS obj, 'ODS' AS layer, COUNT(*) AS rows_cnt FROM ydsh_ods.ods_user
UNION ALL SELECT '用户表',   'DWD', COUNT(*) FROM dwd_user
UNION ALL SELECT '商品表',   'ODS', COUNT(*) FROM ydsh_ods.ods_product
UNION ALL SELECT '商品表',   'DWD', COUNT(*) FROM dwd_product
UNION ALL SELECT '订单表',   'ODS', COUNT(*) FROM ydsh_ods.ods_order
UNION ALL SELECT '订单表',   'DWD', COUNT(*) FROM dwd_order
UNION ALL SELECT '门店表',   'ODS', COUNT(*) FROM ydsh_ods.ods_store
UNION ALL SELECT '明细表',   'ODS', COUNT(*) FROM ydsh_ods.ods_order_item
UNION ALL SELECT '行为表',   'ODS', COUNT(*) FROM ydsh_ods.ods_user_behavior;

-- ############################################################################
-- 二、缺失值处理成效明细
--     每行一个问题类型，fixed_cnt 为本次修复的记录数
-- ############################################################################
SELECT '年龄缺失/异常' AS issue_type, layer, issue_cnt, filled_cnt
FROM (
    SELECT 'ODS' AS layer,
           SUM(CASE WHEN age IS NULL OR age < 1 OR age > 120 THEN 1 ELSE 0 END) AS issue_cnt,
           0 AS filled_cnt
    FROM ydsh_ods.ods_user
    UNION ALL
    SELECT 'DWD',
           SUM(CASE WHEN age IS NULL OR age < 1 OR age > 120 THEN 1 ELSE 0 END),
           SUM(age_is_filled)
    FROM dwd_user
) t
UNION ALL
SELECT '性别缺失', layer, issue_cnt, filled_cnt
FROM (
    SELECT 'ODS' AS layer,
           SUM(CASE WHEN gender IS NULL OR TRIM(gender) = '' THEN 1 ELSE 0 END), 0
    FROM ydsh_ods.ods_user
    UNION ALL
    SELECT 'DWD',
           SUM(CASE WHEN gender IS NULL OR TRIM(gender) = '' THEN 1 ELSE 0 END),
           SUM(CASE WHEN gender = '未知' THEN 1 ELSE 0 END)
    FROM dwd_user
) t2
UNION ALL
SELECT '会员等级缺失', layer, issue_cnt, filled_cnt
FROM (
    SELECT 'ODS' AS layer,
           SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END), 0
    FROM ydsh_ods.ods_user
    UNION ALL
    SELECT 'DWD',
           SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END),
           SUM(CASE WHEN member_level = '普通会员' THEN 1 ELSE 0 END)
    FROM dwd_user
) t3
UNION ALL
SELECT '邮箱缺失（保留空值+标记）', layer, issue_cnt, filled_cnt
FROM (
    SELECT 'ODS' AS layer,
           SUM(CASE WHEN email IS NULL OR TRIM(email) = '' THEN 1 ELSE 0 END), 0
    FROM ydsh_ods.ods_user
    UNION ALL
    SELECT 'DWD',
           SUM(CASE WHEN email IS NULL OR TRIM(email) = '' THEN 1 ELSE 0 END),
           SUM(email_is_null)
    FROM dwd_user
) t4
UNION ALL
SELECT '上架日期缺失', layer, issue_cnt, filled_cnt
FROM (
    SELECT 'ODS' AS layer,
           SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END), 0
    FROM ydsh_ods.ods_product
    UNION ALL
    SELECT 'DWD',
           SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END),
           SUM(launch_date_is_filled)
    FROM dwd_product
) t5;

-- ############################################################################
-- 三、去重处理成效
-- ############################################################################
SELECT '订单主键重复行数' AS issue_type, 'ODS' AS layer,
       COUNT(*) - COUNT(DISTINCT order_id) AS issue_cnt, 0 AS fixed_cnt
FROM ydsh_ods.ods_order
UNION ALL
SELECT '订单主键重复行数', 'DWD',
       COUNT(*) - COUNT(DISTINCT order_id),
       SUM(ods_dup_cnt) - COUNT(*)
FROM dwd_order;

-- ############################################################################
-- 四、清洗前后脏数据总量与修复率（答辩首页数字）
--     口径说明：邮箱缺失属「策略性保留」（不填充假邮箱），
--               故清洗后的统计不计入邮箱，避免虚增未修复数。
-- ############################################################################
SELECT
    SUM(before_issue)                    AS total_issue_before,
    SUM(after_issue)                     AS total_issue_after,
    SUM(before_issue) - SUM(after_issue) AS issue_fixed,
    ROUND((SUM(before_issue) - SUM(after_issue)) * 100.0 / SUM(before_issue), 2) AS fix_rate_pct
FROM (
    SELECT SUM(CASE WHEN age IS NULL OR age < 1 OR age > 120 THEN 1 ELSE 0 END)
         + SUM(CASE WHEN gender IS NULL OR TRIM(gender) = '' THEN 1 ELSE 0 END)
         + SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END)
         + SUM(CASE WHEN email IS NULL OR TRIM(email) = '' THEN 1 ELSE 0 END) AS before_issue,
           0 AS after_issue
    FROM ydsh_ods.ods_user
    UNION ALL
    SELECT SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END), 0
    FROM ydsh_ods.ods_product
    UNION ALL
    SELECT COUNT(*) - COUNT(DISTINCT order_id), 0
    FROM ydsh_ods.ods_order
    UNION ALL
    SELECT 0,
           SUM(CASE WHEN age IS NULL OR age < 1 OR age > 120 THEN 1 ELSE 0 END)
         + SUM(CASE WHEN gender IS NULL OR TRIM(gender) = '' THEN 1 ELSE 0 END)
         + SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END)
    FROM dwd_user
    UNION ALL
    SELECT 0, SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END)
    FROM dwd_product
    UNION ALL
    SELECT 0, COUNT(*) - COUNT(DISTINCT order_id)
    FROM dwd_order
) t;

-- ############################################################################
-- 五、数据一致性保障校验（DWD 层自检）
--     校验条件（三项须同时成立才算 PASS）：
--       ① dwd_order 行数 = 15,000（ods 去重后订单数）
--       ② dwd_order 的 order_id 无重复（dup_left = 0）
--       ③ 明细表引用的订单全部存在于 dwd_order（orphan_item_rows = 0）
-- ############################################################################

-- 5.1 订单表去重结果
SELECT
    COUNT(*)                            AS dwd_order_rows,
    COUNT(DISTINCT order_id)            AS dwd_uniq_orders,
    COUNT(*) - COUNT(DISTINCT order_id) AS dup_left
FROM dwd_order;

-- 5.2 明细表引用的订单是否全部存在（去重未误删有明细的订单）
SELECT
    COUNT(*)                                            AS item_rows_total,
    SUM(CASE WHEN o.order_id IS NULL THEN 1 ELSE 0 END) AS orphan_item_rows
FROM ydsh_ods.ods_order_item i
LEFT JOIN dwd_order o ON i.order_id = o.order_id;
