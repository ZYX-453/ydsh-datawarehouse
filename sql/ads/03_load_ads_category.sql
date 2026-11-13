-- =============================================================================
-- 文件   : sql/ads/03_load_ads_category.sql
-- 作者   : 张宇翔
-- 阶段   : 第 3 周 · 子任务 1 —— ADS 品类销售排名
-- -----------------------------------------------------------------------------
-- 上游：dws_product_month（销售额已按订单实付分摊，合计 = GMV）
-- 字段口径：
--   sales_amt   = sum(dws_product_month.sales_amt)，12 个分区累加
--   qty         = sum(qty)（件数，quantity 为空的行不计）
--   order_cnt   = 该品类涉及的「去重订单数」。不能把 dws_product_month.order_cnt
--                 直接相加——同一订单买同品类多个商品会被重复计数，
--                 故单独从明细侧做 count(DISTINCT order_id)。
--   brand_cnt   = 该品类下「有成交」的品牌数，不是商品表里的品牌总数。
-- 排名：row_number() OVER (ORDER BY sales_amt DESC)，并列时按类目名稳定排序。
-- =============================================================================

DROP TABLE IF EXISTS stg_cat_sales;
CREATE TABLE stg_cat_sales STORED AS ORC AS
SELECT
    COALESCE(category, '未分类')      AS category,
    sum(sales_amt)                    AS sales_amt,
    sum(qty)                          AS qty,
    count(DISTINCT CASE WHEN qty > 0 THEN brand END) AS brand_cnt
FROM ydsh_dws.dws_product_month
GROUP BY COALESCE(category, '未分类');

DROP TABLE IF EXISTS stg_cat_order;
CREATE TABLE stg_cat_order STORED AS ORC AS
SELECT
    COALESCE(p.category, '未分类')    AS category,
    count(DISTINCT i.order_id)        AS order_cnt
FROM ydsh_dwd.dwd_order_item i
JOIN ydsh_dwd.dwd_order o ON i.order_id = o.order_id
LEFT JOIN ydsh_dwd.dim_product p ON i.product_id = p.product_id
WHERE o.is_gmv_included = 1
GROUP BY COALESCE(p.category, '未分类');

INSERT OVERWRITE TABLE ydsh_ads.ads_category_rank
SELECT
    row_number() OVER (ORDER BY s.sales_amt DESC, s.category)  AS rk,
    s.category,
    s.sales_amt,
    s.sales_amt / tot.total_sales                              AS sales_share,
    COALESCE(o.order_cnt, 0)                                   AS order_cnt,
    s.qty,
    s.sales_amt / COALESCE(o.order_cnt, 1)                     AS aov,
    s.brand_cnt
FROM stg_cat_sales s
LEFT JOIN stg_cat_order o ON s.category = o.category
CROSS JOIN (SELECT sum(sales_amt) AS total_sales FROM stg_cat_sales) tot;

DROP TABLE IF EXISTS stg_cat_sales;
DROP TABLE IF EXISTS stg_cat_order;
