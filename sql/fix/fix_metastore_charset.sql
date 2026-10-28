-- ============================================================================
-- 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统
-- Metastore 字符集修复脚本（解决中文注释变问号）
-- ----------------------------------------------------------------------------
-- 文件    : sql/fix/fix_metastore_charset.sql
-- 作者    : 张宇翔
-- 执行    : 在 MySQL 中执行（不是 Hive）
--   docker exec ydsh-mysql mysql -uroot -proot < sql/fix/fix_metastore_charset.sql
--
-- 【问题现象】
--   建表时字段注释写中文，DESC 表时全部显示为 '???'，
--   直接查元数据库 COLUMNS_V2.COMMENT 得到 HEX 值 3F3F3F（问号的 ASCII 码）。
--   但表里的业务数据中文完全正常 —— 说明只影响 DDL 注释，不影响数据。
--
-- 【根因】
--   Hive 4.0.0 官方 schema 文件
--   /opt/hive/scripts/metastore/upgrade/mysql/hive-schema-4.0.0.mysql.sql
--   中把元数据表硬编码为 latin1：
--       `COMMENT` varchar(4000) CHARACTER SET latin1 COLLATE latin1_bin DEFAULT NULL,
--       ) ENGINE=InnoDB DEFAULT CHARSET=latin1;
--   原因是索引长度限制：utf8mb4 下 varchar(767) 的索引会达 3068 字节，
--   超过 InnoDB 3072 字节上限，所以 Hive 官方选了 latin1。
--   latin1 无法表示中文，MySQL 在写入时把非 latin1 字符一律替换为 '?'。
--   这与数据库默认字符集、JDBC 连接参数、容器 LANG 均无关 —— 已逐一验证排除。
--
-- 【为什么不能整表转换】
--   ALTER TABLE COLUMNS_V2 CONVERT TO CHARACTER SET utf8mb4 会失败：
--       ERROR 1071: Specified key was too long; max key length is 3072 bytes
--   因为 COLUMN_NAME varchar(767) 是主键的一部分。
--
-- 【本脚本的做法】
--   只转换「存储注释与参数值的字段」，这些字段都不参与索引，
--   因此不影响索引长度限制。DESC/COMMENT 类字段存储的是用户可见文案，
--   改成 utf8mb4 即可正确保存中文。
--
-- 【执行时机】
--   必须在 metastore 完成 schema 初始化之后、创建业务表之前执行。
--   环境重建（删掉 mysql 数据卷）后需要重新执行一次。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 字段注释（DESC 表时显示的 COMMENT 列）
-- ----------------------------------------------------------------------------
ALTER TABLE metastore.COLUMNS_V2
    MODIFY `COMMENT` varchar(4000) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;

-- ----------------------------------------------------------------------------
-- 库注释、表注释
--   DBS.DESC           —— 库注释（CREATE DATABASE ... COMMENT）
--   TABLE_PARAMS       —— 表注释以 PARAM_KEY='comment' 的形式存在此表
-- ----------------------------------------------------------------------------
ALTER TABLE metastore.DBS
    MODIFY `DESC` varchar(4000) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;

ALTER TABLE metastore.TABLE_PARAMS
    MODIFY `PARAM_VALUE` mediumtext CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;

-- ----------------------------------------------------------------------------
-- 分区字段注释
-- ----------------------------------------------------------------------------
ALTER TABLE metastore.PARTITION_KEYS
    MODIFY `PKEY_COMMENT` varchar(4000) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;

-- ----------------------------------------------------------------------------
-- 其余可能存放中文文案的字段（一次转全，避免遗漏）
-- ----------------------------------------------------------------------------
ALTER TABLE metastore.DATABASE_PARAMS
    MODIFY `PARAM_VALUE` varchar(4000) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;

ALTER TABLE metastore.SD_PARAMS
    MODIFY `PARAM_VALUE` mediumtext CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;

ALTER TABLE metastore.SERDE_PARAMS
    MODIFY `PARAM_VALUE` mediumtext CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;

ALTER TABLE metastore.PARTITION_PARAMS
    MODIFY `PARAM_VALUE` mediumtext CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;

ALTER TABLE metastore.AUX_TABLE
    MODIFY `MT_COMMENT` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;

ALTER TABLE metastore.TYPE_FIELDS
    MODIFY `COMMENT` varchar(256) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;

ALTER TABLE metastore.CTLGS
    MODIFY `DESC` varchar(4000) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL;

-- ----------------------------------------------------------------------------
-- 验证：以下查询应返回 0 行（若还有 latin1 的注释字段，会列出来）
-- ----------------------------------------------------------------------------
SELECT TABLE_NAME, COLUMN_NAME, CHARACTER_SET_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'metastore'
  AND (COLUMN_NAME LIKE '%COMMENT%' OR COLUMN_NAME = 'DESC' OR COLUMN_NAME = 'PARAM_VALUE')
  AND CHARACTER_SET_NAME = 'latin1';

-- 确认关键字段已是 utf8mb4（应输出 utf8mb4）
SELECT TABLE_NAME, COLUMN_NAME, CHARACTER_SET_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'metastore'
  AND TABLE_NAME IN ('COLUMNS_V2', 'DBS', 'TABLE_PARAMS')
  AND (COLUMN_NAME LIKE '%COMMENT%' OR COLUMN_NAME = 'DESC' OR COLUMN_NAME = 'PARAM_VALUE');
