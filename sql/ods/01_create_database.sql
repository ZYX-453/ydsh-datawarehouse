-- ============================================================================
-- 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统
-- ODS 贴源层建库脚本
-- ----------------------------------------------------------------------------
-- 文件    : sql/ods/01_create_database.sql
-- 作者    : 张宇翔
-- 说明    : 创建 ODS 贴源层数据库，后续 DWD / DWS / ADS 分库见各自脚本
-- 执行    : beeline -u jdbc:hive2://localhost:10000 -f 01_create_database.sql
--
-- 【为什么建库不写 LOCATION】
--   容器化 Hive 的 warehouse 是本地文件系统目录（/opt/hive/data/warehouse），
--   不是 HDFS。若硬编码 LOCATION '/user/hive/warehouse/xxx.db'，Hive 会把库路径
--   解析成 file:/user/hive/warehouse/xxx.db，该目录在容器内不存在且无权限创建，
--   建表时会直接报错：
--     MetaException(message:file:/user/hive/warehouse/ydsh_ods.db is not a directory
--                    or unable to create one)
--   因此统一不写 LOCATION，让各库自动落在 hive.metastore.warehouse.dir 之下。
--   这样也便于将来迁移（改 warehouse 配置即可，无需逐库改路径）。
-- ============================================================================

-- ODS 贴源层：与源系统保持一致，不做任何业务加工
CREATE DATABASE IF NOT EXISTS ydsh_ods COMMENT '云购生活-ODS贴源层';

-- 后续分层预留（本周暂不使用，提前建好便于分层管理）
CREATE DATABASE IF NOT EXISTS ydsh_dwd COMMENT '云购生活-DWD明细层';
CREATE DATABASE IF NOT EXISTS ydsh_dws COMMENT '云购生活-DWS汇总层';
CREATE DATABASE IF NOT EXISTS ydsh_ads COMMENT '云购生活-ADS应用层';

-- 查看结果：确认各库的物理路径都落在 warehouse 之下
SHOW DATABASES;
