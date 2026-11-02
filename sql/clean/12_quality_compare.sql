-- ============================================================================
-- 第 2 周 步骤 9：数据质量清洗前后对比统计
-- ----------------------------------------------------------------------------
-- 文件 : sql/clean/12_quality_compare.sql
-- 依赖 : 06~11 各清洗脚本已执行
--
-- 产出 : ydsh_dwd.quality_compare（18 行，五类脏数据逐项对比）
--   列：category / check_item / before_cnt / after_cnt / fix_rate
--   修复率 = (清洗前脏值数 - 清洗后脏值数) / 清洗前脏值数
--
-- 【为什么拆成 6 条语句】
--   Tez 单条语句的 UNION ALL 超过约 4 路就会触发计数器上限 120
--   （第 1 周已验证，第 2 周在本文件上再次复现），故按 3 行一组拆分。
-- ============================================================================

USE ydsh_dwd;

DROP TABLE IF EXISTS quality_compare;
CREATE TABLE quality_compare (
    category    STRING COMMENT '脏数据类别',
    check_item  STRING COMMENT '检查项',
    before_cnt  BIGINT COMMENT '清洗前（ODS）脏值数',
    after_cnt   BIGINT COMMENT '清洗后（DWD）脏值数',
    fix_rate    DOUBLE COMMENT '修复率（%）'
)
COMMENT '数据质量清洗前后对比'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ------------------------------------------------ 1. 缺失值 / 重复值 ----
INSERT INTO quality_compare
SELECT '缺失值', 'user.age 为空', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_user WHERE age IS NULL) b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dim_user WHERE age IS NULL) a
UNION ALL
SELECT '缺失值', 'product.launch_date 为空', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_product WHERE launch_date IS NULL OR trim(launch_date) = '') b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dim_product WHERE launch_date IS NULL) a
UNION ALL
SELECT '重复值', 'order 重复行', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) - count(DISTINCT order_id) c FROM ydsh_ods.ods_order) b
CROSS JOIN (SELECT count(*) - count(DISTINCT order_id) c FROM ydsh_dwd.dwd_order) a;

-- ------------------------------------------------ 2. 异常值（金额/价格/年龄）----
INSERT INTO quality_compare
SELECT '异常值', 'pay_amount 负数或>10万', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_order WHERE pay_amount < 0 OR pay_amount > 100000) b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dwd_order WHERE pay_amount < 0 OR pay_amount > 100000) a
UNION ALL
SELECT '异常值', 'price 负数或>10万', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_product WHERE price < 0 OR price > 100000) b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dim_product WHERE price < 0 OR price > 100000) a
UNION ALL
SELECT '异常值', 'age <=0 或 >=150', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_user WHERE age <= 0 OR age >= 150) b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dim_user WHERE age <= 0 OR age >= 150) a;

-- ------------------------------------------------ 3. 异常值（数量）+ 格式 ----
INSERT INTO quality_compare
SELECT '异常值', 'quantity 不在 [1,50]', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_order_item WHERE quantity < 1 OR quantity > 50) b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dwd_order_item WHERE quantity < 1 OR quantity > 50) a
UNION ALL
SELECT '格式不一致', 'order_date 非 yyyy-MM-dd', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_order WHERE order_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dwd_order WHERE order_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') a
UNION ALL
SELECT '格式不一致', 'order_time 非 HH:mm:ss', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_order WHERE order_time NOT RLIKE '^[0-9]{2}:[0-9]{2}:[0-9]{2}$') b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dwd_order WHERE order_time NOT RLIKE '^[0-9]{2}:[0-9]{2}:[0-9]{2}$') a;

-- ------------------------------------------------ 4. 格式（日期/手机号/行为时间）----
INSERT INTO quality_compare
SELECT '格式不一致', 'register_date 非 yyyy-MM-dd', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_user WHERE register_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dim_user WHERE register_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') a
UNION ALL
SELECT '格式不一致', 'phone 非 11 位纯数字', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_user WHERE phone NOT RLIKE '^[0-9]{11}$') b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dim_user WHERE phone NOT RLIKE '^[0-9]{11}$') a
UNION ALL
SELECT '格式不一致', 'behavior_time 非标准', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_user_behavior WHERE behavior_time NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$') b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dwd_user_behavior WHERE behavior_time NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$') a;

-- ------------------------------------------------ 5. 枚举/业务逻辑（用户+订单）----
-- 【口径说明】"非规范值" = 取值未落在标准值域内、必须改写的行数。
--   注意不能把 male/M/gold/wechat 这类"已知变体"算成规范值 ——
--   它们恰恰是需要被映射掉的行；否则 before_cnt 会虚低到只剩空串。
INSERT INTO quality_compare
SELECT '业务逻辑错误', 'gender 非规范值', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_user WHERE lower(trim(gender)) NOT IN ('男','女','未知')) b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dim_user WHERE gender NOT IN ('男','女','未知')) a
UNION ALL
SELECT '业务逻辑错误', 'member_level 非规范值', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_user WHERE lower(trim(member_level)) NOT IN ('普通会员','银卡会员','金卡会员','钻石会员')) b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dim_user WHERE member_level NOT IN ('普通会员','银卡会员','金卡会员','钻石会员')) a
UNION ALL
SELECT '业务逻辑错误', 'order_status 非规范值', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_order WHERE lower(trim(order_status)) NOT IN ('待支付','已支付','已完成','已取消','退款中')) b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dwd_order WHERE order_status NOT IN ('待支付','已支付','已完成','已取消','退款中')) a;

-- ------------------------------------------------ 6. 枚举/业务逻辑（支付/渠道/行为）----
INSERT INTO quality_compare
SELECT '业务逻辑错误', 'pay_type 非规范值', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_order WHERE lower(trim(pay_type)) NOT IN ('支付宝','微信支付','银行卡','货到付款')) b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dwd_order WHERE pay_type NOT IN ('支付宝','微信支付','银行卡','货到付款')) a
UNION ALL
SELECT '业务逻辑错误', 'channel 非规范值', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
-- channel 的目标值是 'APP' / 'PC官网'（含大写），故用精确比对；
-- 若写成 lower(trim(channel)) NOT IN ('app',...) 会把 170 条 'app' 当成合规漏掉。
FROM (SELECT count(*) c FROM ydsh_ods.ods_order WHERE trim(channel) NOT IN ('APP','小程序','PC官网','门店')) b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dwd_order WHERE channel NOT IN ('APP','小程序','PC官网','门店')) a
UNION ALL
SELECT '业务逻辑错误', 'behavior_type 非规范值', b.c, a.c, CASE WHEN b.c = 0 THEN NULL ELSE round((b.c - a.c) * 100.0 / b.c, 2) END
FROM (SELECT count(*) c FROM ydsh_ods.ods_user_behavior WHERE lower(trim(behavior_type)) NOT IN ('pv','cart','fav','buy')) b
CROSS JOIN (SELECT count(*) c FROM ydsh_dwd.dwd_user_behavior WHERE behavior_type NOT IN ('pv','cart','fav','buy')) a;

-- ---------------------------------------------------------------- 输出 ----
SELECT category, check_item, before_cnt, after_cnt, fix_rate
FROM quality_compare
ORDER BY category, check_item;
