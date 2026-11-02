-- ============================================================================
-- 第 2 周 步骤 3：dim_product 商品维度清洗
-- ----------------------------------------------------------------------------
-- 文件 : sql/clean/07_clean_dim_product.sql
-- 依赖 : 05_rebuild_dwd_tables.sql
--
-- 处理清单：
--   ① category / sub_category / brand ：去除首尾空格（实测 27 条类目带尾空格）
--   ② price ：负数取绝对值；> 100000 视为录入错误置空（实测 20 负 + 16 超大）
--   ③ launch_date ：空值按同（trim 后）类目上架日期中位数补全，类目全空时回退全表中位数
--
-- 【关于 price 阈值为什么用 10 万而不是 P99】
--   实测 pay_amount 的 P99 = 5,510,776 —— 因为异常值本身占 2%，
--   分位数已被脏值污染，用它做阈值等于把脏值当成正常上限。
--   故改用业务硬阈值（单笔金额/单价 10 万）作为主判据，并在报告中说明该结论。
--
-- 【实测差异说明】
--   数据字典称 brand 存在"大小写异常"，实测 600 条品牌均无大小写/空格问题，
--   此处仍做 trim 兜底，但不虚构修复量。
-- ============================================================================

USE ydsh_dwd;

INSERT OVERWRITE TABLE dim_product
SELECT
    s.product_id,
    s.product_name,
    s.category,
    s.sub_category,
    s.brand,
    s.price_clean                                                  AS price,
    CASE WHEN s.price_clean IS NULL AND s.price IS NOT NULL THEN 1
         WHEN s.price_clean <> s.price THEN 1
         ELSE 0 END                                                AS price_is_fixed,
    s.cost,
    s.stock,
    s.status,
    COALESCE(s.launch_date_clean, cm.med_date, gm.med_date)         AS launch_date,
    CASE WHEN s.launch_date_clean IS NULL THEN 1 ELSE 0 END         AS launch_date_is_filled
FROM (
    SELECT
        product_id,
        product_name,
        trim(category)                                                         AS category,
        trim(sub_category)                                                     AS sub_category,
        trim(brand)                                                            AS brand,
        price,
        CASE
            WHEN price < 0 AND abs(price) <= 100000 THEN abs(price)
            WHEN price > 100000 THEN NULL
            ELSE price
        END AS price_clean,
        cost,
        stock,
        status,
        CASE
            WHEN launch_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN launch_date
            WHEN launch_date RLIKE '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$'
                THEN date_format(from_unixtime(unix_timestamp(launch_date, 'yyyy/M/d')), 'yyyy-MM-dd')
            WHEN launch_date RLIKE '^[0-9]{8}$'
                THEN date_format(from_unixtime(unix_timestamp(launch_date, 'yyyyMMdd')), 'yyyy-MM-dd')
            ELSE NULL
        END AS launch_date_clean
    FROM ydsh_ods.ods_product
) s
-- 同类目上架日期中位数
LEFT JOIN (
    SELECT trim(category) AS category,
           date_format(from_unixtime(CAST(percentile_approx(CAST(unix_timestamp(launch_date, 'yyyy-MM-dd') AS BIGINT), cast(0.5 as double), 10000) AS BIGINT)), 'yyyy-MM-dd') AS med_date
    FROM ydsh_ods.ods_product
    WHERE launch_date IS NOT NULL AND trim(launch_date) <> ''
    GROUP BY trim(category)
) cm ON s.category = cm.category
-- 全表上架日期中位数（类目全缺失时兜底）
JOIN (
    SELECT date_format(from_unixtime(CAST(percentile_approx(CAST(unix_timestamp(launch_date, 'yyyy-MM-dd') AS BIGINT), cast(0.5 as double), 10000) AS BIGINT)), 'yyyy-MM-dd') AS med_date
    FROM ydsh_ods.ods_product
    WHERE launch_date IS NOT NULL AND trim(launch_date) <> ''
) gm ON 1 = 1;

-- ---------------------------------------------------------------- 校验 ----
SELECT 'dim_product 行数' AS metric, CAST(count(*) AS STRING) AS val FROM dim_product
UNION ALL
SELECT 'category 值域个数', CAST(count(*) AS STRING) FROM (SELECT category FROM dim_product GROUP BY category) t
UNION ALL
SELECT 'price 负值条数', CAST(sum(CASE WHEN price < 0 THEN 1 ELSE 0 END) AS STRING) FROM dim_product
UNION ALL
SELECT 'price 超10万条数', CAST(sum(CASE WHEN price > 100000 THEN 1 ELSE 0 END) AS STRING) FROM dim_product
UNION ALL
SELECT 'price 已修正条数', CAST(sum(price_is_fixed) AS STRING) FROM dim_product
UNION ALL
SELECT 'launch_date 缺失条数', CAST(sum(CASE WHEN launch_date IS NULL THEN 1 ELSE 0 END) AS STRING) FROM dim_product;

SELECT category, count(*) AS c FROM dim_product GROUP BY category ORDER BY c DESC;
