-- =============================================================================
-- 文件   : sql/ads/04_load_ads_region.sql
-- 作者   : 张宇翔
-- 阶段   : 第 3 周 · 子任务 1 —— ADS 省份排名 + 门店 Top10
-- -----------------------------------------------------------------------------
-- 上游：dws_store_month（月 × 门店）
-- 省份口径：按「门店所在省」归集，不是按用户收货地址（源数据无收货地址字段）。
--   user_cnt 必须从订单明细侧去重统计：dws_store_month.user_cnt 是「门店内去重」，
--   同一个月同一用户跨门店下单会被重复计数，直接相加会虚增。
--   store_cnt 取 dim_store 全量门店（含零成交门店），与「有成交门店」区分说明。
-- =============================================================================

-- ------------------------------------------------------------ 1. 省份排名 ----
DROP TABLE IF EXISTS stg_prov_sales;
CREATE TABLE stg_prov_sales STORED AS ORC AS
SELECT
    COALESCE(s.province, '未知省份')   AS province,
    sum(m.gmv)                        AS gmv,
    sum(m.order_cnt)                  AS order_cnt,
    count(DISTINCT m.store_id)        AS store_cnt
FROM ydsh_dws.dws_store_month m
LEFT JOIN ydsh_dwd.dim_store s ON m.store_id = s.store_id
GROUP BY COALESCE(s.province, '未知省份');

DROP TABLE IF EXISTS stg_prov_user;
CREATE TABLE stg_prov_user STORED AS ORC AS
SELECT
    COALESCE(s.province, '未知省份')   AS province,
    count(DISTINCT o.user_id)         AS user_cnt
FROM ydsh_dwd.dwd_order o
LEFT JOIN ydsh_dwd.dim_store s ON o.store_id = s.store_id
WHERE o.is_gmv_included = 1
GROUP BY COALESCE(s.province, '未知省份');

INSERT OVERWRITE TABLE ydsh_ads.ads_region_rank
SELECT
    row_number() OVER (ORDER BY p.gmv DESC, p.province)   AS rk,
    p.province,
    p.gmv,
    p.gmv / tot.total_gmv                                 AS gmv_share,
    p.order_cnt,
    COALESCE(u.user_cnt, 0)                               AS user_cnt,
    p.store_cnt,
    p.gmv / p.order_cnt                                   AS aov
FROM stg_prov_sales p
LEFT JOIN stg_prov_user u ON p.province = u.province
CROSS JOIN (SELECT sum(gmv) AS total_gmv FROM stg_prov_sales) tot;

DROP TABLE IF EXISTS stg_prov_sales;
DROP TABLE IF EXISTS stg_prov_user;

-- ------------------------------------------------------------ 2. 门店 Top10 ----
DROP TABLE IF EXISTS stg_store_sales;
CREATE TABLE stg_store_sales STORED AS ORC AS
SELECT
    store_id,
    max(store_name) AS store_name,
    max(province)   AS province,
    max(city)       AS city,
    sum(gmv)        AS gmv,
    sum(order_cnt)  AS order_cnt
FROM ydsh_dws.dws_store_month
GROUP BY store_id;

INSERT OVERWRITE TABLE ydsh_ads.ads_store_top10
SELECT
    rk, store_id, store_name, province, city, gmv, order_cnt,
    gmv / order_cnt AS aov
FROM (
    SELECT
        row_number() OVER (ORDER BY gmv DESC, store_id) AS rk,
        store_id, store_name, province, city, gmv, order_cnt
    FROM stg_store_sales
) t
WHERE rk <= 10;

DROP TABLE IF EXISTS stg_store_sales;
