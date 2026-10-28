-- ============================================================================
-- 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统
-- 数据质量预评估（五维度扫描）
-- ----------------------------------------------------------------------------
-- 文件    : sql/quality/01_quality_assessment.sql
-- 作者    : 张宇翔
-- 依赖    : ODS 层 6 张表已导入完成
-- 执行    : beeline -u jdbc:hive2://localhost:10000 -f 01_quality_assessment.sql
--
-- 五维度定义：
--   完整性 Completeness —— 字段空值率（NULL 或空字符串）
--   唯一性 Uniqueness   —— 主键重复率
--   有效性 Validity     —— 枚举取值是否在合法域内
--   一致性 Consistency  —— 同一字段的格式是否统一、跨表关联是否完整
--   准确性 Accuracy     —— 数值是否落在业务合理区间
--
-- 使用方式：逐段执行，把结果填入《数据质量预评估表》(docs/02_数据质量预评估表.md)
-- ============================================================================

USE ydsh_ods;

-- ----------------------------------------------------------------------------
-- 运行参数（解决 Tez 计数器上限问题）
--   Hive 4.0 + Tez 默认每个 DAG 最多 120 个计数器，多表 UNION ALL 会超限：
--     FAILED: Execution Error, return code 2 from TezTask.
--     Counters limit exceeded: Too many counters: 121 max=120
--   该上限需在 tez-site.xml 配置，beeline 中 SET 不生效（已实测）。
--   故本脚本采用拆分写法规避，见第六部分说明。
-- ----------------------------------------------------------------------------
-- 改用 MR 引擎执行：本脚本以轻量校验查询为主，数据量小（最大 6 万行），
-- MR 完全够用，且不受 Tez 计数器上限约束（Tez 上限需改 tez-site.xml，SET 无效）。
-- 使用默认 Tez 引擎。注意事项（均已实测验证）：
--   ① MR 引擎不可用：MR 下 COUNT(*) 恒比实际多 1（ods_store 返回 61，实际 60，
--      关闭 hive.compute.query.using.stats 亦无效），数据校验必须以 Tez 结果为准。
--   ② Tez 计数器上限：每个 DAG 默认最多 120 个计数器，多表 UNION ALL（≥6 表）
--      或 6 组 JOIN 会触发
--        Counters limit exceeded: Too many counters: 121 max=120
--      该上限需在 tez-site.xml 配置，beeline 中 SET tez.counters.max 不生效（已实测）。
--      故本脚本所有多表对比均拆成独立查询，请勿合并回 UNION ALL。
SET hive.vectorized.execution.enabled=false;


-- ############################################################################
-- 一、完整性（Completeness）—— 各表字段空值率
-- ############################################################################

-- 1.1 ods_user：4 个字段存在缺失
SELECT
    COUNT(*)                                                          AS total_rows,
    SUM(CASE WHEN gender       IS NULL OR TRIM(gender)       = '' THEN 1 ELSE 0 END) AS gender_null,
    SUM(CASE WHEN age          IS NULL                            THEN 1 ELSE 0 END) AS age_null,
    SUM(CASE WHEN member_level IS NULL OR TRIM(member_level) = '' THEN 1 ELSE 0 END) AS member_level_null,
    SUM(CASE WHEN email        IS NULL OR TRIM(email)        = '' THEN 1 ELSE 0 END) AS email_null
FROM ods_user;

-- 1.2 ods_product：上架日期存在缺失
SELECT
    COUNT(*)                                                             AS total_rows,
    SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END) AS launch_date_null
FROM ods_product;

-- 1.3 ods_order：主表实测无缺失，此查询用于留证
SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN order_id   IS NULL OR TRIM(order_id)   = '' THEN 1 ELSE 0 END) AS order_id_null,
    SUM(CASE WHEN user_id    IS NULL OR TRIM(user_id)    = '' THEN 1 ELSE 0 END) AS user_id_null,
    SUM(CASE WHEN store_id   IS NULL OR TRIM(store_id)   = '' THEN 1 ELSE 0 END) AS store_id_null,
    SUM(CASE WHEN order_date IS NULL OR TRIM(order_date) = '' THEN 1 ELSE 0 END) AS order_date_null,
    SUM(CASE WHEN pay_amount IS NULL                            THEN 1 ELSE 0 END) AS pay_amount_null
FROM ods_order;

-- 1.4 ods_order_item / ods_user_behavior：留证
SELECT COUNT(*) AS item_total,
       SUM(CASE WHEN quantity   IS NULL THEN 1 ELSE 0 END) AS quantity_null,
       SUM(CASE WHEN unit_price IS NULL THEN 1 ELSE 0 END) AS unit_price_null
FROM ods_order_item;

SELECT COUNT(*) AS behavior_total,
       SUM(CASE WHEN behavior_time IS NULL OR TRIM(behavior_time) = '' THEN 1 ELSE 0 END) AS behavior_time_null
FROM ods_user_behavior;

-- ############################################################################
-- 二、唯一性（Uniqueness）—— 主键重复检测
-- ############################################################################

-- 2.1 ods_order：主键重复（本次清洗重点）
SELECT
    COUNT(*)                                            AS total_rows,
    COUNT(DISTINCT order_id)                            AS distinct_order_id,
    COUNT(*) - COUNT(DISTINCT order_id)                 AS dup_rows,
    ROUND((COUNT(*) - COUNT(DISTINCT order_id)) * 100.0 / COUNT(*), 2) AS dup_rate_pct
FROM ods_order;

-- 2.2 ods_order：重复订单明细（重复行数 / 组数）
SELECT
    COUNT(*)                        AS dup_group_cnt,
    SUM(cnt)                        AS dup_row_cnt,
    MAX(cnt)                        AS max_dup_per_order
FROM (
    SELECT order_id, COUNT(*) AS cnt
    FROM ods_order
    GROUP BY order_id
    HAVING COUNT(*) > 1
) t;

-- 2.3 ods_order：区分「整行完全重复」与「主键重复但内容不同」
--     full_dup_group_cnt   = 整行完全相同的组数（可直接去重）
--     partial_dup_group_cnt = 主键重复但内容有差异的组数（需按业务规则取舍）
SELECT
    SUM(CASE WHEN variant_cnt = 1 THEN 1 ELSE 0 END) AS full_dup_group_cnt,
    SUM(CASE WHEN variant_cnt > 1 THEN 1 ELSE 0 END) AS partial_dup_group_cnt
FROM (
    SELECT order_id,
           COUNT(DISTINCT CONCAT_WS('|', user_id, store_id, order_date, order_time,
                                    CAST(pay_amount AS STRING), CAST(discount_amount AS STRING),
                                    pay_type, order_status, channel)) AS variant_cnt
    FROM ods_order
    GROUP BY order_id
    HAVING COUNT(*) > 1
) t;

-- 2.4 其余各表主键唯一性（留证，预期全部无重复）
--     拆成独立查询：多表 UNION ALL 会累积 Tez 计数器并触发上限报错
SELECT 'ods_user' AS table_name, COUNT(*) AS total_rows,
       COUNT(DISTINCT user_id) AS distinct_pk FROM ods_user;

SELECT 'ods_product' AS table_name, COUNT(*) AS total_rows,
       COUNT(DISTINCT product_id) AS distinct_pk FROM ods_product;

SELECT 'ods_store' AS table_name, COUNT(*) AS total_rows,
       COUNT(DISTINCT store_id) AS distinct_pk FROM ods_store;

SELECT 'ods_order_item' AS table_name, COUNT(*) AS total_rows,
       COUNT(DISTINCT item_id) AS distinct_pk FROM ods_order_item;

SELECT 'ods_user_behavior' AS table_name, COUNT(*) AS total_rows,
       COUNT(DISTINCT behavior_id) AS distinct_pk FROM ods_user_behavior;

-- ############################################################################
-- 三、有效性（Validity）—— 枚举取值合法性
-- ############################################################################

-- 3.1 ods_order.order_status：取值分布（预期 12 种，业务合法值仅 5 种）
SELECT order_status, COUNT(*) AS cnt
FROM ods_order GROUP BY order_status ORDER BY cnt DESC;

-- 3.2 ods_order.order_status：非法取值统计
--     合法域：已完成 / 已支付 / 待支付 / 已取消 / 退款中
SELECT
    SUM(CASE WHEN order_status IN ('已完成','已支付','待支付','已取消','退款中') THEN 1 ELSE 0 END) AS legal_cnt,
    SUM(CASE WHEN order_status NOT IN ('已完成','已支付','待支付','已取消','退款中') THEN 1 ELSE 0 END) AS illegal_cnt,
    ROUND(SUM(CASE WHEN order_status NOT IN ('已完成','已支付','待支付','已取消','退款中') THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 2) AS illegal_rate_pct
FROM ods_order;

-- 3.3 ods_order.pay_type：取值分布（预期 7 种）
SELECT pay_type, COUNT(*) AS cnt
FROM ods_order GROUP BY pay_type ORDER BY cnt DESC;

-- 3.4 ods_order.channel：取值分布（预期 6 种）
SELECT channel, COUNT(*) AS cnt
FROM ods_order GROUP BY channel ORDER BY cnt DESC;

-- 3.5 ods_user.gender：取值分布（预期 8 种）
SELECT gender, COUNT(*) AS cnt
FROM ods_user GROUP BY gender ORDER BY cnt DESC;

-- 3.6 ods_user.member_level：取值分布（预期 12 种）
SELECT member_level, COUNT(*) AS cnt
FROM ods_user GROUP BY member_level ORDER BY cnt DESC;

-- 3.7 ods_user_behavior.behavior_type：取值分布（预期 11 种）
SELECT behavior_type, COUNT(*) AS cnt
FROM ods_user_behavior GROUP BY behavior_type ORDER BY cnt DESC;

-- 3.8 ods_product.category：取值分布（含尾空格，预期 16 种 = 8 类 × 2）
SELECT CONCAT('[', category, ']') AS category_with_bracket, LENGTH(category) AS len, COUNT(*) AS cnt
FROM ods_product GROUP BY category, LENGTH(category) ORDER BY category;

-- 3.9 ods_product.status：取值分布（预期 3 种，合法）
SELECT status, COUNT(*) AS cnt
FROM ods_product GROUP BY status ORDER BY cnt DESC;

-- ############################################################################
-- 四、一致性（Consistency）—— 格式统一性与跨表关联完整性
-- ############################################################################

-- 4.1 ods_user.register_date：3 种格式混用
SELECT
    SUM(CASE WHEN register_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END) AS fmt_iso,      -- 2023-11-25
    SUM(CASE WHEN register_date RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN 1 ELSE 0 END) AS fmt_slash,    -- 2023/11/25
    SUM(CASE WHEN register_date RLIKE '^[0-9]{8}$'                  THEN 1 ELSE 0 END) AS fmt_compact,   -- 20231125
    SUM(CASE WHEN register_date IS NULL OR NOT register_date RLIKE '^([0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{4}/[0-9]{2}/[0-9]{2}|[0-9]{8})$'
             THEN 1 ELSE 0 END) AS fmt_other
FROM ods_user;

-- 4.2 ods_user.phone：带横杠与不带横杠混用
SELECT
    SUM(CASE WHEN phone RLIKE '^[0-9]{11}$'      THEN 1 ELSE 0 END) AS fmt_plain,   -- 13892127520
    SUM(CASE WHEN phone RLIKE '^[0-9]{3}-[0-9]{4}-[0-9]{4}$' THEN 1 ELSE 0 END) AS fmt_dash,  -- 138-9212-7520
    SUM(CASE WHEN phone IS NULL OR NOT phone RLIKE '^([0-9]{11}|[0-9]{3}-[0-9]{4}-[0-9]{4})$'
             THEN 1 ELSE 0 END) AS fmt_other
FROM ods_user;

-- 4.3 ods_order.order_date：实测 100% 斜杠格式（与文档描述不同，以实测为准）
SELECT
    SUM(CASE WHEN order_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END) AS fmt_iso,
    SUM(CASE WHEN order_date RLIKE '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$' THEN 1 ELSE 0 END) AS fmt_slash,
    SUM(CASE WHEN order_date IS NULL OR NOT order_date RLIKE '^([0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{4}/[0-9]{1,2}/[0-9]{1,2})$'
             THEN 1 ELSE 0 END) AS fmt_other
FROM ods_order;

-- 4.4 ods_user_behavior.behavior_time：两种格式混用
SELECT
    SUM(CASE WHEN behavior_time RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' THEN 1 ELSE 0 END) AS fmt_dash,
    SUM(CASE WHEN behavior_time RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}'        THEN 1 ELSE 0 END) AS fmt_slash,
    SUM(CASE WHEN behavior_time IS NULL OR NOT behavior_time RLIKE
             '^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}|[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2})$'
             THEN 1 ELSE 0 END) AS fmt_other
FROM ods_user_behavior;

-- 4.5 跨表关联完整性：孤儿外键检查（预期全部为 0）
--     拆成独立查询：6 组 JOIN 的 UNION ALL 会累积 Tez 计数器并触发上限报错
SELECT 'order_item→order' AS relation, COUNT(*) AS orphan_cnt
FROM ods_order_item i LEFT JOIN ods_order o ON i.order_id = o.order_id
WHERE o.order_id IS NULL;

SELECT 'order_item→product' AS relation, COUNT(*) AS orphan_cnt
FROM ods_order_item i LEFT JOIN ods_product p ON i.product_id = p.product_id
WHERE p.product_id IS NULL;

SELECT 'order→user' AS relation, COUNT(*) AS orphan_cnt
FROM ods_order o LEFT JOIN ods_user u ON o.user_id = u.user_id
WHERE u.user_id IS NULL;

SELECT 'order→store' AS relation, COUNT(*) AS orphan_cnt
FROM ods_order o LEFT JOIN ods_store s ON o.store_id = s.store_id
WHERE s.store_id IS NULL;

SELECT 'behavior→user' AS relation, COUNT(*) AS orphan_cnt
FROM ods_user_behavior b LEFT JOIN ods_user u ON b.user_id = u.user_id
WHERE u.user_id IS NULL;

SELECT 'behavior→product' AS relation, COUNT(*) AS orphan_cnt
FROM ods_user_behavior b LEFT JOIN ods_product p ON b.product_id = p.product_id
WHERE p.product_id IS NULL;

-- 4.6 无明细的订单（预期为 0，保证订单与明细可完全关联）
SELECT COUNT(*) AS order_without_item
FROM ods_order o LEFT JOIN (SELECT DISTINCT order_id FROM ods_order_item) i ON o.order_id = i.order_id
WHERE i.order_id IS NULL;

-- ############################################################################
-- 五、准确性（Accuracy）—— 数值业务合理性
-- ############################################################################

-- 5.1 ods_user.age：缺失 / 非法（<1 或 >120）
SELECT
    COUNT(age)                                                        AS non_null_cnt,
    SUM(CASE WHEN age < 1 OR age > 120 THEN 1 ELSE 0 END)             AS illegal_cnt,
    MIN(age) AS min_age, MAX(age) AS max_age,
    ROUND(AVG(CASE WHEN age BETWEEN 1 AND 120 THEN age END), 2)       AS avg_age_valid,
    ROUND(AVG(age), 2)                                                AS avg_age_raw
FROM ods_user;

-- 5.2 ods_user.age：非法值明细（便于写报告举实例）
SELECT age, COUNT(*) AS cnt FROM ods_user WHERE age < 1 OR age > 120 GROUP BY age ORDER BY age;

-- 5.3 ods_product.price：负数与异常高价（> 10 万视为异常）
SELECT
    COUNT(*)                                                            AS total,
    SUM(CASE WHEN price < 0          THEN 1 ELSE 0 END)                 AS neg_cnt,
    SUM(CASE WHEN price > 100000     THEN 1 ELSE 0 END)                 AS too_high_cnt,
    SUM(CASE WHEN price = 0          THEN 1 ELSE 0 END)                 AS zero_cnt,
    MIN(price) AS min_price, MAX(price) AS max_price,
    ROUND(AVG(CASE WHEN price > 0 AND price <= 100000 THEN price END), 2) AS avg_price_valid
FROM ods_product;

-- 5.4 ods_product：成本价高于售罄价的异常（业务逻辑错误）
SELECT COUNT(*) AS cost_gt_price_cnt
FROM ods_product WHERE cost > price AND price > 0;

-- 5.5 ods_order.pay_amount：负数与超大额
SELECT
    COUNT(*)                                                        AS total,
    SUM(CASE WHEN pay_amount < 0        THEN 1 ELSE 0 END)          AS neg_cnt,
    SUM(CASE WHEN pay_amount = 0        THEN 1 ELSE 0 END)          AS zero_cnt,
    SUM(CASE WHEN pay_amount > 100000   THEN 1 ELSE 0 END)          AS too_high_cnt,
    MIN(pay_amount) AS min_amt, MAX(pay_amount) AS max_amt,
    ROUND(AVG(CASE WHEN pay_amount > 0 AND pay_amount <= 100000 THEN pay_amount END), 2) AS avg_amt_valid
FROM ods_order;

-- 5.6 ods_order：优惠金额大于实付金额（业务逻辑矛盾）
SELECT COUNT(*) AS discount_gt_pay_cnt
FROM ods_order WHERE discount_amount > pay_amount AND pay_amount > 0;

-- 5.7 ods_order_item.quantity：0 值 / 负数 / 超大值（> 50 视为异常）
SELECT
    COUNT(*)                                                      AS total,
    SUM(CASE WHEN quantity = 0        THEN 1 ELSE 0 END)          AS zero_cnt,
    SUM(CASE WHEN quantity < 0        THEN 1 ELSE 0 END)          AS neg_cnt,
    SUM(CASE WHEN quantity > 50       THEN 1 ELSE 0 END)          AS too_large_cnt,
    MIN(quantity) AS min_qty, MAX(quantity) AS max_qty
FROM ods_order_item;

-- 5.8 ods_order_item.unit_price：0 与负值
SELECT
    COUNT(*)                                                    AS total,
    SUM(CASE WHEN unit_price = 0 THEN 1 ELSE 0 END)              AS zero_cnt,
    SUM(CASE WHEN unit_price < 0 THEN 1 ELSE 0 END)              AS neg_cnt,
    MIN(unit_price) AS min_price, MAX(unit_price) AS max_price
FROM ods_order_item;

-- 5.9 ods_order_item.discount：是否落在 [0,1]
SELECT
    COUNT(*)                                                                     AS total,
    SUM(CASE WHEN discount < 0 OR discount > 1 THEN 1 ELSE 0 END)                AS illegal_cnt,
    MIN(discount) AS min_discount, MAX(discount) AS max_discount
FROM ods_order_item;

-- 5.10 ods_store.area：营业面积合理性（< 50 或 > 5000 ㎡ 视为异常）
SELECT
    COUNT(*) AS total,
    SUM(CASE WHEN area < 50 OR area > 5000 THEN 1 ELSE 0 END) AS illegal_cnt,
    MIN(area) AS min_area, MAX(area) AS max_area
FROM ods_store;

-- ############################################################################
-- 六、汇总：一张表看全貌（用于报告首页）
-- ############################################################################
-- 说明：此处刻意拆成 6 条独立查询，而不是一条 6 表 UNION ALL。
--   UNION ALL 6 张表会让 Tez 起 6 个任务并累积计数器，
--   超过 Tez 默认上限（max=120）直接报错：
--     Counters limit exceeded: Too many counters: 121 max=120
--   该上限在 tez-site.xml 中配置，beeline 里 SET tez.counters.max 不生效，
--   故采用拆分写法规避 —— 每张表单独统计，结果同样清晰，且不触发限制。

SELECT 'ods_user'          AS table_name, COUNT(*) AS rows_cnt,
       '有：gender/age/member_level/email' AS null_fields FROM ods_user;

SELECT 'ods_product'       AS table_name, COUNT(*) AS rows_cnt,
       '有：launch_date' AS null_fields FROM ods_product;

SELECT 'ods_store'         AS table_name, COUNT(*) AS rows_cnt,
       '无' AS null_fields FROM ods_store;

SELECT 'ods_order'         AS table_name, COUNT(*) AS rows_cnt,
       '无空值，但主键重复 600 行' AS null_fields FROM ods_order;

SELECT 'ods_order_item'    AS table_name, COUNT(*) AS rows_cnt,
       '无' AS null_fields FROM ods_order_item;

SELECT 'ods_user_behavior' AS table_name, COUNT(*) AS rows_cnt,
       '无' AS null_fields FROM ods_user_behavior;
