-- ============================================================================
-- 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统
-- 数据清洗（一）：缺失值诊断与处理
-- ----------------------------------------------------------------------------
-- 文件    : sql/clean/02_handle_missing_values.sql
-- 作者    : 张宇翔
-- 依赖    : 01_create_dwd_tables.sql 已执行
-- 执行    : beeline -u jdbc:hive2://localhost:10000 -f 02_handle_missing_values.sql
--
-- 【关键说明】为什么不用 UPDATE？
--   《第1周部署操作手册》步骤 8 给出的示例是 `update ... set age = <均值> where ...`。
--   但 Hive 的 UPDATE 仅支持 ACID 事务表（ORC + 分桶 + transactional=true 且需开启
--   hive.support.concurrency / hive.txn.manager 等多项配置），普通表执行 UPDATE 会直接报错：
--       FAILED: SemanticException [Error 10294]: Attempt to do update or delete using transaction manager
--              that does not support these operations.
--   因此本项目统一采用数仓标准做法：**INSERT OVERWRITE 重写目标表**。
--   好处是天然幂等（脚本可重复执行）、无事务依赖、与离线批处理范式一致。
-- ============================================================================

USE ydsh_dwd;

-- ############################################################################
-- 第一步：缺失值诊断（清洗前留证）
-- ############################################################################

-- 1.1 用户表缺失值分布
SELECT
    'ods_user' AS tbl, COUNT(*) AS total,
    SUM(CASE WHEN gender       IS NULL OR TRIM(gender)       = '' THEN 1 ELSE 0 END) AS gender_null,
    SUM(CASE WHEN age          IS NULL                            THEN 1 ELSE 0 END) AS age_null,
    SUM(CASE WHEN age < 1 OR age > 120                            THEN 1 ELSE 0 END) AS age_illegal,
    SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END) AS level_null,
    SUM(CASE WHEN email        IS NULL OR TRIM(email)        = '' THEN 1 ELSE 0 END) AS email_null
FROM ydsh_ods.ods_user;

-- 1.2 商品表缺失值分布
SELECT
    'ods_product' AS tbl, COUNT(*) AS total,
    SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END) AS launch_date_null
FROM ydsh_ods.ods_product;

-- ############################################################################
-- 第二步：计算填充基准值
-- ############################################################################

-- 2.1 有效年龄中位数
--     为何用中位数而非均值：age 存在 200 / -3 / 0 等极端值，均值会被显著拉高。
--     虽然填充前已做区间过滤，但中位数对偏态分布更稳健，是用户画像场景的通行选择。
DROP TABLE IF EXISTS tmp_age_median;
CREATE TABLE tmp_age_median STORED AS ORC AS
SELECT percentile_approx(CAST(age AS DOUBLE), 0.5) AS med_age,
       ROUND(AVG(age), 2)                          AS avg_age,
       COUNT(*)                                    AS valid_cnt
FROM ydsh_ods.ods_user
WHERE age BETWEEN 1 AND 120;

-- 查看中位数与均值差异（用于报告说明选择依据）
SELECT med_age, avg_age, valid_cnt,
       ROUND(med_age - avg_age, 2) AS median_minus_avg
FROM tmp_age_median;

-- 2.2 各类目上架日期中位数（用于补全 ods_product.launch_date 缺失）
--     category 在 ODS 中存在尾空格（8 类变 16 种取值），故按 TRIM(category) 分组，
--     避免同一类目被拆成两组导致中位数计算偏差。
--     日期为 'yyyy-MM-dd' 定长格式，转 unix 时间戳后取中位数再转回字符串。
DROP TABLE IF EXISTS tmp_launch_median;
CREATE TABLE tmp_launch_median STORED AS ORC AS
SELECT TRIM(category) AS category,
       from_unixtime(
           CAST(percentile_approx(unix_timestamp(launch_date, 'yyyy-MM-dd'), 0.5) AS BIGINT),
           'yyyy-MM-dd'
       ) AS med_launch_date
FROM ydsh_ods.ods_product
WHERE launch_date IS NOT NULL
  AND TRIM(launch_date) <> ''
  AND launch_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
GROUP BY TRIM(category);

-- 2.3 全表上架日期中位数（类目级兜底：若某类目全部缺失，则用全表中位数）
DROP TABLE IF EXISTS tmp_launch_global;
CREATE TABLE tmp_launch_global STORED AS ORC AS
SELECT from_unixtime(
           CAST(percentile_approx(unix_timestamp(launch_date, 'yyyy-MM-dd'), 0.5) AS BIGINT),
           'yyyy-MM-dd'
       ) AS med_launch_date
FROM ydsh_ods.ods_product
WHERE launch_date IS NOT NULL
  AND TRIM(launch_date) <> ''
  AND launch_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$';

-- 各类目补全基准值（用于报告留证）
SELECT category, med_launch_date FROM tmp_launch_median ORDER BY category;

-- ############################################################################
-- 第三步：执行缺失值填充（INSERT OVERWRITE 重写目标表）
-- ############################################################################

-- 3.1 dwd_user —— 年龄 / 性别 / 会员等级填充，邮箱保留空值并标记
--     年龄异常值（<1 或 >120）与空值同等处理：统一视为无效观测值并填充。
--     依据：与《部署操作手册》步骤 8 的验证标准一致 ——
--           「清洗后 age 无空值、无负值、无超 120 的异常值」。
INSERT OVERWRITE TABLE dwd_user
SELECT
    u.user_id,
    u.user_name,
    CASE WHEN u.gender IS NULL OR TRIM(u.gender) = '' THEN '未知' ELSE u.gender END AS gender,
    CASE WHEN u.age IS NULL OR u.age < 1 OR u.age > 120
         THEN CAST(ROUND(m.med_age) AS INT)
         ELSE u.age
    END AS age,
    CASE WHEN u.age IS NULL OR u.age < 1 OR u.age > 120 THEN 1 ELSE 0 END AS age_is_filled,
    u.city,
    u.province,
    u.register_date,
    CASE WHEN u.member_level IS NULL OR TRIM(u.member_level) = '' THEN '普通会员' ELSE u.member_level END AS member_level,
    u.phone,
    u.email,
    CASE WHEN u.email IS NULL OR TRIM(u.email) = '' THEN 1 ELSE 0 END AS email_is_null
FROM ydsh_ods.ods_user u
CROSS JOIN tmp_age_median m;

-- 3.2 dwd_product —— 上架日期按类目中位数补全，类目缺失则回退全表中位数
INSERT OVERWRITE TABLE dwd_product
SELECT
    p.product_id,
    p.product_name,
    p.category,
    p.sub_category,
    p.brand,
    p.price,
    p.cost,
    p.stock,
    p.status,
    CASE WHEN p.launch_date IS NULL OR TRIM(p.launch_date) = ''
         THEN COALESCE(cm.med_launch_date, g.med_launch_date)
         ELSE p.launch_date
    END AS launch_date,
    CASE WHEN p.launch_date IS NULL OR TRIM(p.launch_date) = '' THEN 1 ELSE 0 END AS launch_date_is_filled
FROM ydsh_ods.ods_product p
LEFT JOIN tmp_launch_median cm ON TRIM(p.category) = cm.category
CROSS JOIN tmp_launch_global g;

-- ############################################################################
-- 第四步：清洗效果验证
-- ############################################################################

-- 4.1 dwd_user：行数一致 + 年龄无空值无异常 + 标记数量与诊断结果吻合
SELECT
    COUNT(*)                                                              AS total_rows,
    SUM(CASE WHEN age IS NULL                    THEN 1 ELSE 0 END)       AS age_still_null,
    SUM(CASE WHEN age < 1 OR age > 120           THEN 1 ELSE 0 END)       AS age_still_illegal,
    SUM(CASE WHEN gender IS NULL OR TRIM(gender) = ''       THEN 1 ELSE 0 END) AS gender_still_null,
    SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END) AS level_still_null,
    SUM(age_is_filled)                                                    AS age_filled_cnt,
    SUM(email_is_null)                                                    AS email_null_cnt,
    MIN(age) AS min_age, MAX(age) AS max_age
FROM dwd_user;

-- 4.2 dwd_product：上架日期无空值，补全条数应等于诊断出的缺失数
SELECT
    COUNT(*)                                                                   AS total_rows,
    SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END) AS launch_still_null,
    SUM(launch_date_is_filled)                                                 AS launch_filled_cnt
FROM dwd_product;

-- 4.3 填充结果抽样目检（确认填充值合理、标记正确）
SELECT user_id, gender, age, age_is_filled, member_level, email_is_null
FROM dwd_user
WHERE age_is_filled = 1 OR email_is_null = 1
LIMIT 10;

-- 4.4 商品补全结果抽样（按类目查看补全到了什么日期）
SELECT category, launch_date, launch_date_is_filled, COUNT(*) AS cnt
FROM dwd_product
WHERE launch_date_is_filled = 1
GROUP BY category, launch_date, launch_date_is_filled;

-- 4.5 清洗前后对比汇总（用于《数据质量预评估表》前后对比章节）
--     注意：此处用 UNION ALL 纵向展开而非横向子查询，
--     因为 Hive 不支持在 SELECT 列表中书写标量子查询（(SELECT ...) 形式），
--     横向对比需改用 JOIN 或聚合，纵向展开是最稳且最易读的写法。
SELECT '用户表' AS obj, 'ODS' AS layer, COUNT(*) AS rows_cnt,
       SUM(CASE WHEN age IS NULL OR age < 1 OR age > 120 THEN 1 ELSE 0 END)
     + SUM(CASE WHEN gender IS NULL OR TRIM(gender) = '' THEN 1 ELSE 0 END)
     + SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END) AS issue_cnt
FROM ydsh_ods.ods_user
UNION ALL
SELECT '用户表', 'DWD', COUNT(*),
       SUM(CASE WHEN age IS NULL OR age < 1 OR age > 120 THEN 1 ELSE 0 END)
     + SUM(CASE WHEN gender IS NULL OR TRIM(gender) = '' THEN 1 ELSE 0 END)
     + SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END)
FROM dwd_user
UNION ALL
SELECT '商品表', 'ODS', COUNT(*),
       SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END)
FROM ydsh_ods.ods_product
UNION ALL
SELECT '商品表', 'DWD', COUNT(*),
       SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END)
FROM dwd_product;

-- 清理临时表（保留 tmp_age_median 便于报告引用，如需清理取消注释）
-- DROP TABLE IF EXISTS tmp_age_median;
-- DROP TABLE IF EXISTS tmp_launch_median;
-- DROP TABLE IF EXISTS tmp_launch_global;
