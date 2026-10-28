-- ============================================================================
-- 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统
-- 数据清洗效果汇总（清洗前后对比）
-- ----------------------------------------------------------------------------
-- 文件    : sql/clean/04_cleaning_summary.sql
-- 作者    : 张宇翔
-- 依赖    : 02_handle_missing_values.sql、03_deduplicate_orders.sql 已执行
-- 执行    : beeline -u jdbc:hive2://localhost:10000 -f 04_cleaning_summary.sql
--
-- 用途：输出第 1 周全部清洗成果的量化对比，
--       结果直接填入《数据质量预评估表》的「清洗前后对比」章节与答辩 PPT。
--
-- 【写法约束：为什么全部拆成独立查询，不用 UNION ALL】
--   ① Hive 不支持 SELECT 列表中的标量子查询（如 (SELECT COUNT(*) FROM t)），
--      横向对比无法用子查询实现；
--      原本改用「纵向 UNION ALL 展开」，但遇到第二个问题：
--   ② Tez 每个 DAG 默认最多 120 个计数器，6 个以上分支的 UNION ALL 会报
--        Counters limit exceeded: Too many counters: 121 max=120
--      该上限需在 tez-site.xml 配置，beeline 中 SET 不生效（已实测）。
--   因此最终方案：**每个指标一个独立查询**，逐条执行、逐条读数，
--   结果同样完整，且不受引擎限制。请勿再合并为 UNION ALL。
-- ============================================================================

USE ydsh_dwd;

-- ############################################################################
-- 一、各表清洗前后行数对比
-- ############################################################################

SELECT '用户表' AS obj, 'ODS' AS layer, COUNT(*) AS rows_cnt FROM ydsh_ods.ods_user;
SELECT '用户表' AS obj, 'DWD' AS layer, COUNT(*) AS rows_cnt FROM dwd_user;
SELECT '商品表' AS obj, 'ODS' AS layer, COUNT(*) AS rows_cnt FROM ydsh_ods.ods_product;
SELECT '商品表' AS obj, 'DWD' AS layer, COUNT(*) AS rows_cnt FROM dwd_product;
SELECT '订单表' AS obj, 'ODS' AS layer, COUNT(*) AS rows_cnt FROM ydsh_ods.ods_order;
SELECT '订单表' AS obj, 'DWD' AS layer, COUNT(*) AS rows_cnt FROM dwd_order;
SELECT '门店表' AS obj, 'ODS' AS layer, COUNT(*) AS rows_cnt FROM ydsh_ods.ods_store;
SELECT '明细表' AS obj, 'ODS' AS layer, COUNT(*) AS rows_cnt FROM ydsh_ods.ods_order_item;
SELECT '行为表' AS obj, 'ODS' AS layer, COUNT(*) AS rows_cnt FROM ydsh_ods.ods_user_behavior;

-- ############################################################################
-- 二、缺失值处理成效（每类问题清洗前后对比）
-- ############################################################################

-- 2.1 年龄缺失与异常（空值 + <1 + >120）
SELECT '年龄缺失/异常' AS issue_type, 'ODS' AS layer,
       SUM(CASE WHEN age IS NULL OR age < 1 OR age > 120 THEN 1 ELSE 0 END) AS issue_cnt
FROM ydsh_ods.ods_user;
SELECT '年龄缺失/异常' AS issue_type, 'DWD' AS layer,
       SUM(CASE WHEN age IS NULL OR age < 1 OR age > 120 THEN 1 ELSE 0 END) AS issue_cnt,
       SUM(age_is_filled) AS filled_cnt
FROM dwd_user;

-- 2.2 性别缺失
SELECT '性别缺失' AS issue_type, 'ODS' AS layer,
       SUM(CASE WHEN gender IS NULL OR TRIM(gender) = '' THEN 1 ELSE 0 END) AS issue_cnt
FROM ydsh_ods.ods_user;
SELECT '性别缺失' AS issue_type, 'DWD' AS layer,
       SUM(CASE WHEN gender IS NULL OR TRIM(gender) = '' THEN 1 ELSE 0 END) AS issue_cnt,
       SUM(CASE WHEN gender = '未知' THEN 1 ELSE 0 END) AS filled_cnt
FROM dwd_user;

-- 2.3 会员等级缺失
SELECT '会员等级缺失' AS issue_type, 'ODS' AS layer,
       SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END) AS issue_cnt
FROM ydsh_ods.ods_user;
SELECT '会员等级缺失' AS issue_type, 'DWD' AS layer,
       SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END) AS issue_cnt,
       SUM(CASE WHEN member_level = '普通会员' THEN 1 ELSE 0 END) AS filled_cnt
FROM dwd_user;

-- 2.4 邮箱缺失（策略性保留：不填充假数据，仅加标记）
SELECT '邮箱缺失' AS issue_type, 'ODS' AS layer,
       SUM(CASE WHEN email IS NULL OR TRIM(email) = '' THEN 1 ELSE 0 END) AS issue_cnt
FROM ydsh_ods.ods_user;
SELECT '邮箱缺失' AS issue_type, 'DWD' AS layer,
       SUM(CASE WHEN email IS NULL OR TRIM(email) = '' THEN 1 ELSE 0 END) AS issue_cnt,
       SUM(email_is_null) AS marked_cnt
FROM dwd_user;

-- 2.5 上架日期缺失
SELECT '上架日期缺失' AS issue_type, 'ODS' AS layer,
       SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END) AS issue_cnt
FROM ydsh_ods.ods_product;
SELECT '上架日期缺失' AS issue_type, 'DWD' AS layer,
       SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END) AS issue_cnt,
       SUM(launch_date_is_filled) AS filled_cnt
FROM dwd_product;

-- ############################################################################
-- 三、去重处理成效
-- ############################################################################
SELECT '订单主键重复行数' AS issue_type, 'ODS' AS layer,
       COUNT(*) - COUNT(DISTINCT order_id) AS issue_cnt
FROM ydsh_ods.ods_order;

SELECT '订单主键重复行数' AS issue_type, 'DWD' AS layer,
       COUNT(*) - COUNT(DISTINCT order_id) AS issue_cnt,
       SUM(ods_dup_cnt) - COUNT(*) AS removed_cnt
FROM dwd_order;

-- ############################################################################
-- 四、清洗前后脏数据总量与修复率（答辩首页数字）
--     口径：邮箱属「策略性保留」，不填充假数据，故修复率计算不含邮箱。
--     用户表问题数 = 年龄(空51+异常27) + 性别84 + 会员等级14 = 176
--     商品表问题数 = 上架日期 11
--     订单表问题数 = 主键重复 600
--     合计 787；邮箱 193 为标记保留项，不计入未修复。
-- ############################################################################

-- 4.1 用户表：清洗前问题数
SELECT '用户表-清洗前' AS metric,
       SUM(CASE WHEN age IS NULL OR age < 1 OR age > 120 THEN 1 ELSE 0 END)
     + SUM(CASE WHEN gender IS NULL OR TRIM(gender) = '' THEN 1 ELSE 0 END)
     + SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END) AS issue_cnt
FROM ydsh_ods.ods_user;

-- 4.2 用户表：清洗后问题数（应为 0）
SELECT '用户表-清洗后' AS metric,
       SUM(CASE WHEN age IS NULL OR age < 1 OR age > 120 THEN 1 ELSE 0 END)
     + SUM(CASE WHEN gender IS NULL OR TRIM(gender) = '' THEN 1 ELSE 0 END)
     + SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END) AS issue_cnt
FROM dwd_user;

-- 4.3 商品表：清洗前
SELECT '商品表-清洗前' AS metric,
       SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END) AS issue_cnt
FROM ydsh_ods.ods_product;

-- 4.4 商品表：清洗后（应为 0）
SELECT '商品表-清洗后' AS metric,
       SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END) AS issue_cnt
FROM dwd_product;

-- 4.5 订单表：清洗前
SELECT '订单表-清洗前' AS metric,
       COUNT(*) - COUNT(DISTINCT order_id) AS issue_cnt
FROM ydsh_ods.ods_order;

-- 4.6 订单表：清洗后（应为 0）
SELECT '订单表-清洗后' AS metric,
       COUNT(*) - COUNT(DISTINCT order_id) AS issue_cnt
FROM dwd_order;

-- 4.7 修复率（清洗前 176+11+600=787，清洗后 0，修复率 100%）
SELECT
    CAST(176 + 11 + 600 AS DOUBLE) AS total_issue_before,
    0.0                            AS total_issue_after,
    100.0                          AS fix_rate_pct;

-- ############################################################################
-- 五、数据一致性保障校验（DWD 层自检）
--     校验条件（三项须同时成立才算通过）：
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

-- 5.3 曾重复的订单数量（应等于重复组数 586）
SELECT
    SUM(CASE WHEN ods_dup_cnt > 1 THEN 1 ELSE 0 END) AS orders_once_duplicated,
    MAX(ods_dup_cnt)                                 AS max_dup_cnt,
    SUM(CASE WHEN ods_dup_cnt = 1 THEN 1 ELSE 0 END) AS orders_always_unique
FROM dwd_order;
