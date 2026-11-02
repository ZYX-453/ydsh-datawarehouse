-- ============================================================================
-- 第 2 周 步骤 2：dim_user 用户维度清洗
-- ----------------------------------------------------------------------------
-- 文件 : sql/clean/06_clean_dim_user.sql
-- 依赖 : 05_rebuild_dwd_tables.sql（dim_user / dim_member_level 已建）
--
-- 处理清单：
--   ① gender        ：男/M/male → 男；女/F/female → 女；其余（含空）→ 未知
--   ② member_level  ：12 种取值 → 4 个标准值，通过 JOIN dim_member_level 完成
--   ③ age           ：≤0 或 ≥150 视为异常 → 置空 → 用有效年龄中位数填充
--   ④ register_date ：yyyy-MM-dd / yyyy/MM/dd / yyyyMMdd → 统一 yyyy-MM-dd
--   ⑤ phone         ：去连字符 → 11 位纯数字，仍不合规的置空
--   ⑥ region        ：province + city 字段合并（任务书子任务 3 要求）
--
-- 【关键】日期统一不能用 regexp_replace(date,'/','-')
--   实测 ods_user.register_date 含 100 条 'yyyy/MM/dd'，看似可以只换分隔符，
--   但 ods_order.order_date 全部是 'yyyy/M/d'（月份/日不补零），
--   单纯 replace 会得到 '2024-7-26' —— 不是标准 yyyy-MM-dd。
--   故此处统一走 unix_timestamp + date_format 两条分支，保证真正补齐前导零。
-- ============================================================================

USE ydsh_dwd;

INSERT OVERWRITE TABLE dim_user
SELECT
    b.user_id,
    b.user_name,
    b.gender_std,
    COALESCE(b.age_clean, CAST(m.med AS INT))                     AS age,
    CASE WHEN b.age_clean IS NULL THEN 1 ELSE 0 END               AS age_is_filled,
    b.city,
    b.province,
    concat_ws('-', b.province, b.city)                            AS region,
    b.register_date_std,
    COALESCE(ml.level_name, '普通会员')                            AS member_level,
    COALESCE(ml.level_rank, 1)                                    AS level_rank,
    b.phone_std,
    b.email,
    CASE WHEN b.email IS NULL OR trim(b.email) = '' THEN 1 ELSE 0 END AS email_is_null
FROM (
    SELECT
        user_id,
        user_name,
        CASE
            WHEN lower(trim(gender)) IN ('男', 'm', 'male')   THEN '男'
            WHEN lower(trim(gender)) IN ('女', 'f', 'female') THEN '女'
            ELSE '未知'
        END AS gender_std,
        CASE WHEN age <= 0 OR age >= 150 THEN NULL ELSE age END AS age_clean,
        trim(city)     AS city,
        trim(province) AS province,
        CASE
            WHEN register_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                THEN register_date
            WHEN register_date RLIKE '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$'
                THEN date_format(from_unixtime(unix_timestamp(register_date, 'yyyy/M/d')), 'yyyy-MM-dd')
            WHEN register_date RLIKE '^[0-9]{8}$'
                THEN date_format(from_unixtime(unix_timestamp(register_date, 'yyyyMMdd')), 'yyyy-MM-dd')
            ELSE NULL
        END AS register_date_std,
        trim(member_level) AS member_level_raw,
        CASE
            WHEN regexp_replace(trim(phone), '-', '') RLIKE '^[0-9]{11}$'
                THEN regexp_replace(trim(phone), '-', '')
            ELSE NULL
        END AS phone_std,
        email
    FROM ydsh_ods.ods_user
) b
-- 有效年龄中位数（排除异常值后计算，避免 200/-3 把中位数带偏）
JOIN (
    SELECT percentile_approx(CAST(age AS DOUBLE), cast(0.5 as double), 10000) AS med
    FROM ydsh_ods.ods_user
    WHERE age > 0 AND age < 150
) m ON 1 = 1
LEFT JOIN dim_member_level ml
    ON lower(b.member_level_raw) = ml.src_value;

-- ---------------------------------------------------------------- 校验 ----
-- 预期：gender 收敛为 3 个值；member_level 收敛为 4 个值；无空日期/手机号
SELECT 'dim_user 行数' AS metric, CAST(count(*) AS STRING) AS val FROM dim_user
UNION ALL
SELECT 'gender 值域个数', CAST(count(*) AS STRING) FROM (SELECT gender FROM dim_user GROUP BY gender) t
UNION ALL
SELECT 'member_level 值域个数', CAST(count(*) AS STRING) FROM (SELECT member_level FROM dim_user GROUP BY member_level) t
UNION ALL
SELECT 'age 填充条数', CAST(sum(age_is_filled) AS STRING) FROM dim_user
UNION ALL
SELECT 'register_date 非标准条数', CAST(sum(CASE WHEN register_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 0 ELSE 1 END) AS STRING) FROM dim_user
UNION ALL
SELECT 'phone 非11位条数', CAST(sum(CASE WHEN phone RLIKE '^[0-9]{11}$' THEN 0 ELSE 1 END) AS STRING) FROM dim_user;

SELECT gender, count(*) AS c FROM dim_user GROUP BY gender ORDER BY c DESC;
SELECT member_level, level_rank, count(*) AS c FROM dim_user GROUP BY member_level, level_rank ORDER BY level_rank;
