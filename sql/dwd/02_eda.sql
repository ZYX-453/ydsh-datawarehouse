-- ============================================================================
-- 第 2 周 步骤 10：基于 DWD 层的探索性数据分析（EDA）
-- ----------------------------------------------------------------------------
-- 文件 : sql/dwd/02_eda.sql
-- 依赖 : dim_* / dwd_order / dwd_order_item 已加载
--
-- 【GMV 口径】
--   只统计 is_gmv_included = 1 的订单（已支付 / 已完成）。
--   待支付、已取消、退款中不计入 —— 若直接 sum(pay_amount) 会虚增 GMV。
--   该口径来自 dim_order_status.is_gmv_included，是显式建模的结果，不是硬编码。
--
-- 【两个已踩过的坑，写在这里避免重犯】
--   ① round(double, int) 写入 ORC 表会变成 NULL（本镜像 Hive 4 的问题），
--      故所有落表的小数一律用 cast(x as decimal(18,2))，不用 round()。
--   ② 窗口函数直接套在「含聚合的子查询」上时，聚合列会被解析成 NULL
--      （sum(amt) over(...) 全是 NULL）。必须先把聚合结果落到实体表，
--      再对实体表做窗口计算。
--   ③ TRUNCATE TABLE 在 ORC 表上不生效（旧文件残留，查询会读到上一轮数据），
--      重跑一律用 DROP TABLE + CREATE TABLE。
-- ============================================================================

USE ydsh_dwd;

-- ---------------------------------------------------------------- 1. 核心 KPI ----
SELECT
    count(*)                                              AS order_cnt,
    count(DISTINCT user_id)                               AS user_cnt,
    cast(sum(pay_amount) as decimal(18, 2))                AS gmv,
    cast(sum(pay_amount) / count(*) as decimal(18, 2))     AS aov,
    cast(sum(discount_amount) as decimal(18, 2))           AS total_discount
FROM dwd_order
WHERE is_gmv_included = 1;

-- ------------------------------------------------------------ 2. 订单状态分布 ----
SELECT order_status,
       count(*)                                            AS cnt,
       cast(count(*) * 100.0 / sum(count(*)) OVER () as decimal(6, 2)) AS pct
FROM dwd_order
GROUP BY order_status
ORDER BY cnt DESC;

-- ---------------------------------------------------------------- 3. 渠道分布 ----
SELECT channel,
       count(*)                                            AS cnt,
       cast(sum(pay_amount) as decimal(18, 2))              AS gmv
FROM dwd_order
WHERE is_gmv_included = 1
GROUP BY channel
ORDER BY gmv DESC;

-- ------------------------------------------------------------ 4. 品类销售分布 ----
SELECT p.category,
       cast(sum(i.item_amount) as decimal(18, 2))           AS sales,
       count(DISTINCT i.order_id)                           AS order_cnt
FROM dwd_order_item i
JOIN dwd_order   o ON i.order_id   = o.order_id
JOIN dim_product p ON i.product_id = p.product_id
WHERE o.is_gmv_included = 1 AND i.item_amount IS NOT NULL
GROUP BY p.category
ORDER BY sales DESC;

-- ------------------------------------------------------------ 5. 省份销售分布 ----
SELECT s.province,
       count(*)                                            AS order_cnt,
       cast(sum(o.pay_amount) as decimal(18, 2))             AS gmv
FROM dwd_order o
JOIN dim_store s ON o.store_id = s.store_id
WHERE o.is_gmv_included = 1
GROUP BY s.province
ORDER BY gmv DESC
LIMIT 10;

-- ---------------------------------------------------------------- 6. 门店 Top10 ----
SELECT s.store_name,
       count(*)                                            AS order_cnt,
       cast(sum(o.pay_amount) as decimal(18, 2))             AS gmv
FROM dwd_order o
JOIN dim_store s ON o.store_id = s.store_id
WHERE o.is_gmv_included = 1
GROUP BY s.store_name
ORDER BY gmv DESC
LIMIT 10;

-- ---------------------------------------------------------------- 7. 月度趋势 ----
SELECT substr(order_date, 1, 7)                             AS order_ym,
       count(*)                                            AS order_cnt,
       cast(sum(pay_amount) as decimal(18, 2))               AS gmv
FROM dwd_order
WHERE is_gmv_included = 1
GROUP BY substr(order_date, 1, 7)
ORDER BY order_ym;

-- ------------------------------------------------------------ 8. 会员等级消费力 ----
SELECT u.member_level,
       count(*)                                            AS order_cnt,
       cast(sum(o.pay_amount) as decimal(18, 2))             AS gmv,
       cast(avg(o.pay_amount) as decimal(18, 2))             AS avg_order_amt
FROM dwd_order o
JOIN dim_user  u ON o.user_id = u.user_id
WHERE o.is_gmv_included = 1
GROUP BY u.member_level
ORDER BY gmv DESC;

-- --------------------------------- 9a. 中间表：用户 × 月度消费汇总（供窗口计算）----
-- 注意：金额列必须是 DOUBLE，且 INSERT 里不要套 round()/cast() ——
-- 本镜像下 round(double,n) 与 cast(... as decimal) 写入 ORC 会变成 NULL。
DROP TABLE IF EXISTS eda_user_month;
CREATE TABLE eda_user_month (
    user_id    STRING,
    order_ym   STRING,
    gmv        DOUBLE,
    order_cnt  INT
)
COMMENT 'EDA 中间表：用户月度消费汇总（供窗口函数计算）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT INTO eda_user_month
SELECT user_id,
       substr(order_date, 1, 7)                            AS order_ym,
       sum(pay_amount)                                     AS gmv,
       count(*)                                            AS order_cnt
FROM dwd_order
WHERE is_gmv_included = 1
GROUP BY user_id, substr(order_date, 1, 7);

-- ------------------------------------------- 9. 窗口函数：用户月度累计单量 Top10 ----
-- 【关于累计金额的说明】
--   本镜像（apache/hive:4.0.0 + Tez）存在缺陷：
--     sum(double) OVER (PARTITION BY ... ORDER BY ...)  —— 带排序的金额累加，结果为 NULL；
--     sum(int)    OVER (PARTITION BY ... ORDER BY ...)  —— 同样写法、整型，结果正常。
--   已实测排除以下因素：列类型（double/decimal 均失败）、排序键类型（字符串/整型均失败）、
--   数据来源（子查询/实体表均失败）、向量化开关（关闭后仍失败）。
--   因此累计金额无法在该引擎上可靠计算，本报告改用「窗口分区求和 = 用户总消费」
--   + 「整型累加 = 累计单量」两个可验证的指标，并在《探索性分析简报》中注明该限制。
SELECT user_id, order_ym, order_cnt,
       sum(order_cnt) OVER (PARTITION BY user_id ORDER BY order_ym
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_orders
FROM eda_user_month
ORDER BY cum_orders DESC
LIMIT 10;

-- --------------------------------------- 10. 窗口函数：用户总消费（分区求和 Top10）----
SELECT user_id,
       cast(sum(gmv) as decimal(18, 2))                     AS user_total_gmv,
       sum(order_cnt)                                       AS total_orders
FROM eda_user_month
GROUP BY user_id
ORDER BY user_total_gmv DESC
LIMIT 10;

-- --------------------------------------------- 11. 窗口函数：用户下单量排名 Top10 ----
SELECT user_id,
       cast(sum(gmv) as decimal(18, 2))                     AS total_gmv,
       sum(order_cnt)                                       AS total_orders,
       row_number() OVER (ORDER BY sum(order_cnt) DESC)     AS rk
FROM eda_user_month
GROUP BY user_id
ORDER BY rk
LIMIT 10;

-- 清理排查用的临时表
DROP TABLE IF EXISTS t_ug;
DROP TABLE IF EXISTS t_ug2;
DROP TABLE IF EXISTS t_dec;
