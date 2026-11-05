-- ============================================================================
-- 第 2 周 步骤 5：dwd_order 订单事实表清洗与加载（按年月分区）
-- ----------------------------------------------------------------------------
-- 文件 : sql/clean/09_clean_dwd_order.sql
-- 依赖 : 05_rebuild_dwd_tables.sql（表 + 码表已建）
--
-- 处理清单：
--   ① 重复订单：order_id 去重，15600 → 15000（保留每个 order_id 的首条）
--   ② order_status ：12 种取值 → 5 标准值，通过 JOIN map_order_status
--   ③ pay_type     ：7 种取值 → 4 标准值，通过 JOIN map_pay_type
--   ④ channel      ：6 种取值（含大小写） → 4 标准值
--   ⑤ pay_amount   ：负数取绝对值；> 100000 置空（实测 310 负 + 312 超大）
--   ⑥ order_date   ：yyyy/M/d（非补零斜杠） → yyyy-MM-dd
--   ⑦ order_time   ：H:mm:ss（小时未补零） → HH:mm:ss
--   ⑧ order_timestamp：order_date + order_time 合并（子任务 3 要求）
--   ⑨ 按 order_ym（yyyy-MM）动态分区写入
--
-- 【为什么拆成四段执行 —— Tez 计数器硬上限】
--   把去重窗口、多个 CASE、2 个码表 JOIN、动态分区写放在一条 INSERT 里，
--   Tez 指标数会超过硬上限 120，报：
--     Counters limit exceeded: Too many counters: 121 max=120
--   实测结论（本项目已验证）：
--     · SET tez.counters.max=2000 不生效 —— 该值由 AM 从 tez-site.xml 读取，
--       会话级 SET 传不到，改了也还是 120；
--     · 切 MR 引擎（hive.execution.engine=mr）虽然不报错，但写入行数会多 1 行
--       （实测 15600 条写出 15601 条、去重后 15001 条），数据不可信，不能用；
--     · 唯一可靠的办法是拆 DAG，让每条语句的算子数低于上限。
--   另一个放大因素：同一个表达式在 SELECT 里重复出现（如 lower(trim(channel))
--   在 4 个分支各写一次），CBO 会展开成多份算子。故所有规范化只在第 1 段做一次，
--   后续段只引用列名。
--
--   第 1 段：去重 + 枚举小写归一（window）      → stg_dedup
--   第 2 段：日期/时间/金额/渠道规范化（纯标量）  → stg_a_order
--   第 3 段：关联码表 + 拼时间戳/分区键（2 JOIN） → stg_order_enum
--   第 4 段：写入按年月分区的事实表              → dwd_order
--
-- 【为什么日期必须走 unix_timestamp 而不是 regexp_replace】
--   实测 ods_order.order_date 的 15,600 行全部是 'yyyy/M/d'：
--     iso 格式 0 行、斜杠格式 15,600 行、纯 8 位数字 0 行。
--   直接 regexp_replace(order_date,'/','-') 会得到 '2024-7-26' —— 缺前导零，
--   不是标准 yyyy-MM-dd，扫描时"看着通过、实则不合规"。
--   必须用 unix_timestamp(s,'yyyy/M/d') + date_format 才真正补齐零。
--   （register_date 才存在 8 位数字格式，order_date 没有，故此处只判两种。）
--
-- 【为什么时间解析用 regexp_extract 而不是 split】
--   split() 返回 array，Hive 向量化窗口算子（VectorPTF）不支持 complex type，
--   会抛 "No complex type support: LIST"。regexp_extract 返回 string，安全。
--
-- 【关于 order_status 中 1/2/3/4 的映射假设】
--   数据字典未给出状态码含义，四种码值分布均匀（169~204 条），判断为随机植入。
--   按电商标准状态机顺序映射：1=待支付 2=已支付 3=已完成 4=已取消。
--   该假设已写入《数据质量清洗报告》的"处理策略"与"遗留问题说明"。
-- ============================================================================

USE ydsh_dwd;

SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;

-- ============ 第 1 段：去重 + 枚举小写归一 ============
DROP TABLE IF EXISTS stg_dedup;
CREATE TABLE stg_dedup (
    order_id     STRING,
    user_id      STRING,
    store_id     STRING,
    order_date   STRING,
    order_time   STRING,
    pay_amount   DOUBLE,
    discount_amount DOUBLE,
    pay_type_l   STRING,
    status_l     STRING,
    channel_l    STRING,
    ods_dup_cnt  INT
)
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE stg_dedup
SELECT
    d.order_id,
    d.user_id,
    d.store_id,
    d.order_date,
    d.order_time,
    d.pay_amount,
    d.discount_amount,
    lower(trim(d.pay_type))     AS pay_type_l,
    lower(trim(d.order_status)) AS status_l,
    lower(trim(d.channel))      AS channel_l,
    d.dup_cnt                   AS ods_dup_cnt
FROM (
    SELECT
        order_id, user_id, store_id, order_date, order_time,
        pay_amount, discount_amount, pay_type, order_status, channel,
        row_number() OVER (PARTITION BY order_id ORDER BY order_time) AS rn,
        count(*)    OVER (PARTITION BY order_id)                      AS dup_cnt
    FROM ydsh_ods.ods_order
) d
WHERE d.rn = 1;

-- ============ 第 2 段：日期/时间/金额/渠道规范化 ============
DROP TABLE IF EXISTS stg_a_order;
CREATE TABLE stg_a_order (
    order_id         STRING,
    user_id          STRING,
    store_id         STRING,
    order_date_std   STRING,
    order_time_std   STRING,
    pay_amount_raw   DOUBLE,
    pay_amount_clean DOUBLE,
    discount_amount  DOUBLE,
    pay_type_l       STRING,
    status_l         STRING,
    channel_std      STRING,
    ods_dup_cnt      INT
)
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE stg_a_order
SELECT
    s.order_id,
    s.user_id,
    s.store_id,
    CASE
        WHEN s.order_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN s.order_date
        WHEN s.order_date RLIKE '^[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}$'
            THEN date_format(from_unixtime(unix_timestamp(s.order_date, 'yyyy/M/d')), 'yyyy-MM-dd')
        ELSE NULL
    END AS order_date_std,
    concat_ws(':',
        lpad(regexp_extract(s.order_time, '^([0-9]{1,2}):', 1), 2, '0'),
        lpad(regexp_extract(s.order_time, ':([0-9]{1,2}):', 1), 2, '0'),
        lpad(regexp_extract(s.order_time, ':([0-9]{1,2})$', 1), 2, '0')
    ) AS order_time_std,
    s.pay_amount AS pay_amount_raw,
    CASE
        WHEN s.pay_amount < 0 AND abs(s.pay_amount) <= 100000 THEN abs(s.pay_amount)
        WHEN s.pay_amount > 100000 THEN NULL
        ELSE s.pay_amount
    END AS pay_amount_clean,
    s.discount_amount,
    s.pay_type_l,
    s.status_l,
    CASE
        WHEN s.channel_l = 'app'            THEN 'APP'
        WHEN s.channel_l IN ('pc', 'pc官网') THEN 'PC官网'
        WHEN s.channel_l = '小程序'          THEN '小程序'
        WHEN s.channel_l = '门店'            THEN '门店'
        ELSE s.channel_l
    END AS channel_std,
    s.ods_dup_cnt
FROM stg_dedup s;

-- ============ 第 3 段：关联码表 + 拼时间戳/分区键 ============
DROP TABLE IF EXISTS stg_order_enum;
CREATE TABLE stg_order_enum (
    order_id         STRING,
    user_id          STRING,
    store_id         STRING,
    order_date       STRING,
    order_time       STRING,
    order_timestamp  STRING,
    pay_amount       DOUBLE,
    discount_amount  DOUBLE,
    pay_type         STRING,
    order_status     STRING,
    is_gmv_included  INT,
    channel          STRING,
    ods_dup_cnt      INT,
    amt_fix_flag     INT,
    order_ym         STRING
)
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE stg_order_enum
SELECT
    a.order_id,
    a.user_id,
    a.store_id,
    a.order_date_std                                        AS order_date,
    a.order_time_std                                        AS order_time,
    concat(a.order_date_std, ' ', a.order_time_std)          AS order_timestamp,
    a.pay_amount_clean                                      AS pay_amount,
    a.discount_amount,
    COALESCE(pt.pay_name, '其他')                            AS pay_type,
    COALESCE(st.status_name, '未知')                         AS order_status,
    COALESCE(st.is_gmv_included, 0)                         AS is_gmv_included,
    a.channel_std                                           AS channel,
    a.ods_dup_cnt,
    CASE
        WHEN a.pay_amount_clean IS NULL AND a.pay_amount_raw IS NOT NULL THEN 2
        WHEN a.pay_amount_clean <> a.pay_amount_raw THEN 1
        ELSE 0
    END AS amt_fix_flag,
    substr(a.order_date_std, 1, 7)                          AS order_ym
FROM stg_a_order a
LEFT JOIN map_pay_type pt      ON a.pay_type_l = pt.src_value
LEFT JOIN map_order_status st  ON a.status_l   = st.src_value;

-- ============ 第 4 段：写入分区事实表 ============
INSERT OVERWRITE TABLE dwd_order PARTITION (order_ym)
SELECT
    order_id, user_id, store_id, order_date, order_time, order_timestamp,
    pay_amount, discount_amount, pay_type, order_status, is_gmv_included,
    channel, ods_dup_cnt, amt_fix_flag, order_ym
FROM stg_order_enum;

-- 清理中间表，保持 DWD 命名空间干净
DROP TABLE IF EXISTS stg_dedup;
DROP TABLE IF EXISTS stg_a_order;
DROP TABLE IF EXISTS stg_order_enum;

-- ---------------------------------------------------------------- 校验 ----
-- 注意：校验 SQL 不能写成 11 路 UNION ALL —— Tez 指标数会再次超过 120。
-- 拆成 3 组各自 UNION ALL，每组 ≤4 路。
SELECT 'dwd_order 行数' AS metric, CAST(count(*) AS STRING) AS val FROM dwd_order
UNION ALL SELECT '去重掉的行数', CAST(15600 - count(*) AS STRING) FROM dwd_order
UNION ALL SELECT 'order_id 唯一数', CAST(count(DISTINCT order_id) AS STRING) FROM dwd_order
UNION ALL SELECT '分区个数', CAST(count(*) AS STRING) FROM (SELECT order_ym FROM dwd_order GROUP BY order_ym) t;

SELECT 'order_status 值域个数' AS metric, CAST(count(*) AS STRING) AS val FROM (SELECT order_status FROM dwd_order GROUP BY order_status) t
UNION ALL SELECT 'pay_type 值域个数', CAST(count(*) AS STRING) FROM (SELECT pay_type FROM dwd_order GROUP BY pay_type) t
UNION ALL SELECT 'channel 值域个数', CAST(count(*) AS STRING) FROM (SELECT channel FROM dwd_order GROUP BY channel) t;

SELECT 'pay_amount 负值条数' AS metric, CAST(sum(CASE WHEN pay_amount < 0 THEN 1 ELSE 0 END) AS STRING) AS val FROM dwd_order
UNION ALL SELECT 'pay_amount 超10万条数', CAST(sum(CASE WHEN pay_amount > 100000 THEN 1 ELSE 0 END) AS STRING) FROM dwd_order
UNION ALL SELECT 'order_date 非标准条数', CAST(sum(CASE WHEN order_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 0 ELSE 1 END) AS STRING) FROM dwd_order
UNION ALL SELECT 'order_time 非标准条数', CAST(sum(CASE WHEN order_time RLIKE '^[0-9]{2}:[0-9]{2}:[0-9]{2}$' THEN 0 ELSE 1 END) AS STRING) FROM dwd_order;

SELECT order_status, count(*) AS c FROM dwd_order GROUP BY order_status ORDER BY c DESC;
SELECT pay_type, count(*) AS c FROM dwd_order GROUP BY pay_type ORDER BY c DESC;
SELECT channel, count(*) AS c FROM dwd_order GROUP BY channel ORDER BY c DESC;
