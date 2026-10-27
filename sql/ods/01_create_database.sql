-- ============================================================================
-- 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统
-- ODS 贴源层建库脚本
-- ----------------------------------------------------------------------------
-- 文件    : sql/ods/01_create_database.sql
-- 作者    : 张宇翔
-- 说明    : 创建 ODS 贴源层数据库，后续 DWD / DWS / ADS 分库见各自脚本
-- 执行    : beeline -u jdbc:hive2://localhost:10000 -f 01_create_database.sql
-- ============================================================================

-- ODS 贴源层：与源系统保持一致，不做任何业务加工
CREATE DATABASE IF NOT EXISTS ydsh_ods
COMMENT '云购生活-ODS贴源层'
LOCATION '/user/hive/warehouse/ydsh_ods.db';

-- 后续分层预留（本周暂不使用，提前建好便于分层管理）
CREATE DATABASE IF NOT EXISTS ydsh_dwd COMMENT '云购生活-DWD明细层';
CREATE DATABASE IF NOT EXISTS ydsh_dws COMMENT '云购生活-DWS汇总层';
CREATE DATABASE IF NOT EXISTS ydsh_ads COMMENT '云购生活-ADS应用层';

-- 查看结果
SHOW DATABASES;
