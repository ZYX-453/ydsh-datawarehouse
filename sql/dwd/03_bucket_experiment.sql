-- =============================================================================
-- 03_bucket_experiment.sql    分桶表实验（任务书 子任务6「尝试分桶表的使用」）
-- -----------------------------------------------------------------------------
-- 目的：
--   验证 Hive 分桶表的建表、写入、桶文件物理分布，以及优化器在什么条件下
--   才会选择 bucket map join。
--
-- 定位说明（重要）：
--   本项目 dwd_order 仅 15,000 行 / 12 个分区，Map Join 已能覆盖全部关联场景，
--   分桶在此量级下【没有性能收益】。本脚本属于语法与机制验证，不参与主链路，
--   单独成文件、不改动 dwd_order 本身，跑失败也不影响交付。
--
-- 字段对照（踩过的坑）：
--   dwd_order 里【没有 product_id 和 quantity】——商品信息在 dwd_order_item 明细表，
--   订单粒度只到"一笔订单一个金额"。第2周部署手册里写的
--   `dwd_order o join dim_product p on o.product_id = p.product_id` 是错的，
--   照抄会报 SemanticException [Error 10004] Invalid column reference。
--
-- 执行：由 run_all.sh 的 week2 阶段串行调用（beeline -f）
-- =============================================================================

USE ydsh_dwd;

SET hive.enforce.bucketing = true;
SET hive.optimize.bucketmapjoin = true;

-- -----------------------------------------------------------------------------
-- 1. 清理上一次实验产物
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS dwd_order_bucket;

-- -----------------------------------------------------------------------------
-- 2. 建分桶表
--    刻意去掉分区：分区与分桶叠加时桶文件会按分区各自分裂，
--    15,000 行 × 12 分区 × 16 桶 = 上千个小文件，既看不出分布也无演示价值。
-- -----------------------------------------------------------------------------
CREATE TABLE dwd_order_bucket (
    order_id        STRING  COMMENT '订单ID（分桶键）',
    user_id         STRING  COMMENT '用户ID',
    store_id        STRING  COMMENT '门店ID',
    order_date      STRING  COMMENT '下单日期 yyyy-MM-dd',
    order_time      STRING  COMMENT '下单时刻 HH:mm:ss',
    order_timestamp STRING  COMMENT '下单时间戳 yyyy-MM-dd HH:mm:ss',
    pay_amount      DOUBLE  COMMENT '实付金额',
    discount_amount DOUBLE  COMMENT '优惠金额',
    pay_type        STRING  COMMENT '支付方式（中文标准值）',
    order_status    STRING  COMMENT '订单状态（中文标准值）',
    is_gmv_included INT     COMMENT '是否计入 GMV 口径',
    channel         STRING  COMMENT '下单渠道（中文标准值）'
)
CLUSTERED BY (order_id) INTO 16 BUCKETS
STORED AS ORC;

-- -----------------------------------------------------------------------------
-- 3. 写入数据
--    分桶表写入会强制走 reduce 阶段，桶数 = 16 即 reduce 数 = 16
-- -----------------------------------------------------------------------------
INSERT OVERWRITE TABLE dwd_order_bucket
SELECT
    order_id,
    user_id,
    store_id,
    order_date,
    order_time,
    order_timestamp,
    pay_amount,
    discount_amount,
    pay_type,
    order_status,
    is_gmv_included,
    channel
FROM dwd_order;

-- -----------------------------------------------------------------------------
-- 4. 校验：行数应与 dwd_order 一致（15,000）
-- -----------------------------------------------------------------------------
SELECT '分桶表行数' AS check_item, COUNT(*) AS cnt FROM dwd_order_bucket;

-- -----------------------------------------------------------------------------
-- 5. 校验：桶分布是否均匀
--    Hive 分桶用 hash(分桶键) mod 桶数，故用同一表达式分组即可观测。
--    理想情况 16 桶各约 937 行。
-- -----------------------------------------------------------------------------
SELECT
    pmod(hash(order_id), 16) AS bucket_no,
    COUNT(*)                 AS row_cnt
FROM dwd_order_bucket
GROUP BY pmod(hash(order_id), 16)
ORDER BY bucket_no;

-- -----------------------------------------------------------------------------
-- 6. 桶文件物理分布（实际文件数）
--    预期 Num Files = 16，文件命名 000000_0 ... 000015_0
--
--    踩坑：本项目 Hive 跑在 local 文件系统（无 HDFS），
--      ① `dfs -ls /user/hive/...` 报 "Error while processing statement: null"；
--      ② `! ls ...`（beeline shell 转义）在 `-f 脚本` 模式下报 "Unknown command"，
--         该语法只在交互模式可用。
--    故改用元数据口径：DESCRIBE FORMATTED 的 Num Files 字段即桶文件数，
--    纯 SQL 可验证，且在本地/ HDFS 两种模式下行为一致。
--    容器内实际 `ls` 结果见 docs/07_数仓架构设计.md 第 4.2 节。
-- -----------------------------------------------------------------------------
DESCRIBE FORMATTED dwd_order_bucket;

-- -----------------------------------------------------------------------------
-- 7. bucket map join 对照实验
--    实测结论（Hive 4.0.0 + Tez + local FS）：
--      场景 A 默认配置           -> Map Join + BROADCAST_EDGE（右表广播，分桶无用武之地）
--      场景 B 关闭 map join 转换 -> Merge Join + 双侧 SHUFFLE（回退成普通 shuffle join）
--      两者都【没有】出现 BucketMapJoin 算子。
--    原因：1.5 万行小表，CBO 判定广播成本最低；bucket map join 的收益
--          建立在大表之间免 shuffle，本量级下根本轮不到它。
--    真正的验证见第 8 段（加 SORTED BY 试图触发 SMB join）。
-- -----------------------------------------------------------------------------
EXPLAIN
SELECT a.order_status, COUNT(*) AS cnt
FROM dwd_order_bucket a
JOIN dwd_order_bucket b ON a.order_id = b.order_id
GROUP BY a.order_status;

SET hive.auto.convert.join = false;

EXPLAIN
SELECT a.order_status, COUNT(*) AS cnt
FROM dwd_order_bucket a
JOIN dwd_order_bucket b ON a.order_id = b.order_id
GROUP BY a.order_status;

SELECT a.order_status, COUNT(*) AS cnt
FROM dwd_order_bucket a
JOIN dwd_order_bucket b ON a.order_id = b.order_id
GROUP BY a.order_status
ORDER BY cnt DESC;

SET hive.auto.convert.join = true;

-- -----------------------------------------------------------------------------
-- 8. SMB join（Sort-Merge-Bucket）变体：补上 SORTED BY 再试
--    SMB join 的硬前提是「同分桶键 + 同桶数 + 桶内有序」，
--    仅 CLUSTERED BY 不够，必须 SORTED BY。
--
--    实测结论：即使补齐 SORTED BY 并开启
--      hive.enforce.sorting / hive.auto.convert.sortmerge.join /
--      hive.optimize.bucketmapjoin.sortedmerge，
--    执行计划仍是 Merge Join + 双侧 SHUFFLE，SMB 未被触发。
--    本项目据此判定：分桶在 Tez + 万级数据下【无性能收益】，
--    保留为语法验证，不进入主链路。
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_smb_probe;

CREATE TABLE tmp_smb_probe (
    order_id     STRING,
    order_status STRING
)
CLUSTERED BY (order_id) SORTED BY (order_id) INTO 16 BUCKETS
STORED AS ORC;

SET hive.enforce.sorting = true;

INSERT OVERWRITE TABLE tmp_smb_probe
SELECT order_id, order_status FROM dwd_order_bucket;

SET hive.auto.convert.join = false;
SET hive.auto.convert.sortmerge.join = true;
SET hive.optimize.bucketmapjoin.sortedmerge = true;

EXPLAIN
SELECT a.order_status, COUNT(*) AS cnt
FROM tmp_smb_probe a
JOIN tmp_smb_probe b ON a.order_id = b.order_id
GROUP BY a.order_status;

-- 复位会话参数，避免影响后续脚本
SET hive.auto.convert.join = true;
SET hive.auto.convert.sortmerge.join = false;
SET hive.optimize.bucketmapjoin.sortedmerge = false;
SET hive.enforce.sorting = false;

-- 实验产物清理：tmp_ 表不留在 DWD 层
DROP TABLE IF EXISTS tmp_smb_probe;

