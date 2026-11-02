-- ============================================================================
-- 第 2 周 步骤 8：dim_date 时间维度生成
-- ----------------------------------------------------------------------------
-- 文件 : sql/dwd/01_dim_date.sql
-- 依赖 : 05_rebuild_dwd_tables.sql（dim_date 已建）
--
-- 无源表，按业务数据覆盖区间（2024 全年）生成日历维度。
--   2024-01-01 是周一，故 day_of_week = pmod(datediff(dt,'2024-01-01'),7)+1 即周一=1。
--   Hive 的 dayofweek() 中 1=周日、7=周六，据此判定周末。
-- ============================================================================

USE ydsh_dwd;

INSERT OVERWRITE TABLE dim_date
SELECT
    date_format(dt, 'yyyy-MM-dd')                          AS date_key,
    year(dt)                                               AS year,
    quarter(dt)                                            AS quarter,
    month(dt)                                              AS month,
    day(dt)                                                AS day,
    weekofyear(dt)                                         AS week_of_year,
    pmod(datediff(dt, '2024-01-01'), 7) + 1                AS day_of_week,
    CASE WHEN dayofweek(dt) IN (1, 7) THEN 1 ELSE 0 END    AS is_weekend,
    date_format(dt, 'yyyy-MM')                             AS year_month
-- 【为什么不用 sequence(0,365)】
--   apache/hive:4.0.0 镜像未注册 sequence() 表生成函数，直接调用报
--   SemanticException [Error 10011]: Invalid function sequence。
--   改用已有表（ods_user 1000 行）生成 1..366 的行号，再叠加到起始日期上。
FROM (
    SELECT date_add('2024-01-01', rn - 1) AS dt
    FROM (
        SELECT row_number() OVER (ORDER BY user_id) AS rn
        FROM ydsh_ods.ods_user
    ) n
    WHERE rn <= 366
) s;

-- 校验：应为 366 行（2024 是闰年）
SELECT COUNT(*) AS dim_date_rows,
       COUNT(DISTINCT date_key) AS distinct_days,
       MIN(date_key) AS min_day,
       MAX(date_key) AS max_day,
       SUM(is_weekend) AS weekend_days
FROM dim_date;
