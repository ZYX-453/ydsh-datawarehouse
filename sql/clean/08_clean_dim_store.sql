-- ============================================================================
-- 第 2 周 步骤 4：dim_store 门店维度清洗
-- ----------------------------------------------------------------------------
-- 文件 : sql/clean/08_clean_dim_store.sql
-- 依赖 : 05_rebuild_dwd_tables.sql
--
-- 门店表脏数据较少（数据字典未标注），仍做统一处理以保证口径一致：
--   ① 所有文本字段去首尾空格
--   ② open_date 统一 yyyy-MM-dd
--   ③ region = province + city 字段合并
-- ============================================================================

USE ydsh_dwd;

INSERT OVERWRITE TABLE dim_store
SELECT
    store_id,
    store_name,
    trim(province)  AS province,
    trim(city)      AS city,
    trim(district)  AS district,
    trim(address)   AS address,
    concat_ws('-', trim(province), trim(city)) AS region,
    CASE
        WHEN open_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN open_date
        WHEN open_date RLIKE '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$'
            THEN date_format(from_unixtime(unix_timestamp(open_date, 'yyyy/M/d')), 'yyyy-MM-dd')
        WHEN open_date RLIKE '^[0-9]{8}$'
            THEN date_format(from_unixtime(unix_timestamp(open_date, 'yyyyMMdd')), 'yyyy-MM-dd')
        ELSE open_date
    END AS open_date,
    area,
    trim(manager)   AS manager
FROM ydsh_ods.ods_store;

-- 校验
SELECT 'dim_store 行数' AS metric, CAST(count(*) AS STRING) AS val FROM dim_store
UNION ALL
SELECT 'province 值域个数', CAST(count(*) AS STRING) FROM (SELECT province FROM dim_store GROUP BY province) t
UNION ALL
SELECT 'open_date 非标准条数', CAST(sum(CASE WHEN open_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 0 ELSE 1 END) AS STRING) FROM dim_store;
