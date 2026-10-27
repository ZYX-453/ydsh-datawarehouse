-- ============================================================================
-- 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统
-- ODS 贴源层数据导入脚本（6 张 CSV）
-- ----------------------------------------------------------------------------
-- 文件    : sql/ods/03_load_ods_data.sql
-- 作者    : 张宇翔
-- 依赖    : 01_create_database.sql、02_create_ods_tables.sql 已执行完毕
--
-- 【执行前置条件】CSV 必须已存在于 HiveServer2 容器的 /data/ 目录下。
--   方式 A（推荐，docker-compose 已挂载）：宿主机 ./data 映射到容器 /data
--   方式 B（挂载失败时兜底）：docker cp data/. hive-server:/data/
--   注意：LOAD DATA LOCAL 里的 "local" 指"容器内本地路径"，不是宿主机路径。
--
-- 【路径说明】本机项目路径 F:\企业项目实战 含中文，个别 Docker 版本挂载中文路径
--   可能失败。若 /data/ 下看不到文件，一律改用方式 B 的 docker cp。
-- ============================================================================

USE ydsh_ods;

-- ----------------------------------------------------------------------------
-- 导入前：清空目标表，保证脚本可重复执行（幂等）
-- ----------------------------------------------------------------------------
TRUNCATE TABLE ods_user;
TRUNCATE TABLE ods_product;
TRUNCATE TABLE ods_store;
TRUNCATE TABLE ods_order;
TRUNCATE TABLE ods_order_item;
TRUNCATE TABLE ods_user_behavior;

-- ----------------------------------------------------------------------------
-- 逐表导入
-- ----------------------------------------------------------------------------
LOAD DATA LOCAL INPATH '/data/ods_user.csv'           OVERWRITE INTO TABLE ods_user;
LOAD DATA LOCAL INPATH '/data/ods_product.csv'        OVERWRITE INTO TABLE ods_product;
LOAD DATA LOCAL INPATH '/data/ods_store.csv'          OVERWRITE INTO TABLE ods_store;
LOAD DATA LOCAL INPATH '/data/ods_order.csv'          OVERWRITE INTO TABLE ods_order;
LOAD DATA LOCAL INPATH '/data/ods_order_item.csv'     OVERWRITE INTO TABLE ods_order_item;
LOAD DATA LOCAL INPATH '/data/ods_user_behavior.csv'  OVERWRITE INTO TABLE ods_user_behavior;

-- ============================================================================
-- 导入后校验（三项，缺一不可）
-- ============================================================================

-- 【校验 1】行数比对：与《项目总说明与模拟数据字典》4.1 预期行数逐表核对
--   预期：user=1000 product=600 store=60 order=15600 order_item=37549 behavior=60000
--   合计：114,809
SELECT 'ods_user'          AS table_name, COUNT(*) AS row_cnt,  1000 AS expect FROM ods_user
UNION ALL SELECT 'ods_product',       COUNT(*),   600  FROM ods_product
UNION ALL SELECT 'ods_store',         COUNT(*),    60  FROM ods_store
UNION ALL SELECT 'ods_order',         COUNT(*), 15600  FROM ods_order
UNION ALL SELECT 'ods_order_item',    COUNT(*), 37549  FROM ods_order_item
UNION ALL SELECT 'ods_user_behavior', COUNT(*), 60000  FROM ods_user_behavior;

-- 【校验 2】BOM 残留检查：首字段不应带 BOM（UTF-8 编码为 EF BB BF）
--   用 HEX 比对字节，避免转义字符在不同 Hive 版本下的解析歧义。
--   期望结果：三列全部为 0。若不为 0，说明 BOM 未随表头跳过。
SELECT
    SUM(CASE WHEN HEX(SUBSTR(user_id,    1, 1)) = 'EFBBBF' THEN 1 ELSE 0 END) AS user_bom,
    SUM(CASE WHEN HEX(SUBSTR(product_id, 1, 1)) = 'EFBBBF' THEN 1 ELSE 0 END) AS product_bom,
    SUM(CASE WHEN HEX(SUBSTR(order_id,   1, 1)) = 'EFBBBF' THEN 1 ELSE 0 END) AS order_bom
FROM (
    SELECT user_id, CAST(NULL AS STRING) AS product_id, CAST(NULL AS STRING) AS order_id FROM ods_user
    UNION ALL
    SELECT CAST(NULL AS STRING), product_id, CAST(NULL AS STRING) FROM ods_product
    UNION ALL
    SELECT CAST(NULL AS STRING), CAST(NULL AS STRING), order_id FROM ods_order
) t;

-- 【校验 3】CRLF 残留检查：末字段不应带 '\r'（ASCII 0x0D）
--   期望结果：三列全部为 0。若不为 0，说明 LINES TERMINATED BY 未生效，
--   改用 docs/01_环境搭建笔记.md「问题 4」中的 LF 预处理方案。
SELECT
    SUM(CASE WHEN HEX(SUBSTR(channel,    -1)) = '0D' THEN 1 ELSE 0 END) AS order_channel_cr,
    SUM(CASE WHEN HEX(SUBSTR(email,      -1)) = '0D' THEN 1 ELSE 0 END) AS user_email_cr,
    SUM(CASE WHEN HEX(SUBSTR(session_id, -1)) = '0D' THEN 1 ELSE 0 END) AS behavior_session_cr
FROM (
    SELECT channel, CAST(NULL AS STRING) AS email, CAST(NULL AS STRING) AS session_id FROM ods_order
    UNION ALL
    SELECT CAST(NULL AS STRING), email, CAST(NULL AS STRING) FROM ods_user
    UNION ALL
    SELECT CAST(NULL AS STRING), CAST(NULL AS STRING), session_id FROM ods_user_behavior
) t;

-- 【抽样目检】各表前 5 行，人工确认字段未错位
SELECT * FROM ods_user            LIMIT 5;
SELECT * FROM ods_order           LIMIT 5;
SELECT * FROM ods_order_item      LIMIT 5;
