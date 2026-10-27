-- ============================================================================
-- 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统
-- DWD 明细层建表脚本（第 1 周：缺失值处理 + 重复值去重）
-- ----------------------------------------------------------------------------
-- 文件    : sql/clean/01_create_dwd_tables.sql
-- 作者    : 张宇翔
-- 依赖    : ODS 层 6 张表已导入完成
-- 执行    : beeline -u jdbc:hive2://localhost:10000 -f 01_create_dwd_tables.sql
--
-- 设计说明：
--   1) 存储格式统一用 ORC：列式存储 + 压缩，较 TEXTFILE 体积减少约 70%，
--      且为后续 DWS/ADS 聚合查询提供更好的 IO 效率。这是企业级数仓的通行做法。
--   2) DWD 层保留明细粒度（一行 = 一条业务记录），不做任何聚合。
--   3) 第 1 周仅处理「缺失值」与「重复值」两类问题；
--      枚举归一化、异常值修正、格式统一属第 2 周范围，ODS 中的其他脏数据在此层原样保留。
--   4) 新增 is_filled / is_null 等标记字段，用于追溯「哪些值是原始值、哪些是加工值」，
--      保证数据可溯源 —— 这是数仓规范性的重要体现，答辩时可作为亮点。
-- ============================================================================

USE ydsh_dwd;

-- ----------------------------------------------------------------------------
-- 1. dwd_user —— 用户明细表（缺失值处理）
--    相对 ODS 的变更：
--      age          : 空值/异常值(−3,0,150,200) → 用有效年龄中位数填充
--      gender       : 空值 → '未知'
--      member_level : 空值 → '普通会员'
--      email        : 空值保留，新增 email_is_null 标记
--      age_is_filled: 标记该行 age 是否为填充值（1=填充，0=原始）
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS dwd_user;
CREATE TABLE dwd_user (
    user_id        STRING  COMMENT '用户编号',
    user_name      STRING  COMMENT '用户姓名',
    gender         STRING  COMMENT '性别（缺失已填充为未知；枚举归一化属第2周）',
    age            INT     COMMENT '年龄（缺失与异常已填充为中位数）',
    age_is_filled  INT     COMMENT '年龄是否为填充值：1=填充 0=原始',
    city           STRING  COMMENT '城市',
    province       STRING  COMMENT '省份',
    register_date  STRING  COMMENT '注册日期（格式统一属第2周）',
    member_level   STRING  COMMENT '会员等级（缺失已填充为普通会员）',
    phone          STRING  COMMENT '手机号',
    email          STRING  COMMENT '邮箱（允许为空）',
    email_is_null  INT     COMMENT '邮箱是否缺失：1=缺失 0=有值'
)
COMMENT '用户明细表-DWD层'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ----------------------------------------------------------------------------
-- 2. dwd_product —— 商品明细表（缺失值处理）
--    相对 ODS 的变更：
--      launch_date  : 空值 → 用同（TRIM 后）类目其他商品的上架日期中位数补全；
--                     若该类目全部缺失，回退到全表上架日期中位数
--      launch_date_is_filled: 标记是否为补全值
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS dwd_product;
CREATE TABLE dwd_product (
    product_id              STRING  COMMENT '商品编号',
    product_name            STRING  COMMENT '商品名称',
    category                STRING  COMMENT '一级类目（尾空格清洗属第2周）',
    sub_category            STRING  COMMENT '二级类目',
    brand                   STRING  COMMENT '品牌',
    price                   DOUBLE  COMMENT '售价（异常值修正属第2周）',
    cost                    DOUBLE  COMMENT '成本价',
    stock                   INT     COMMENT '库存数量',
    status                  STRING  COMMENT '状态',
    launch_date             STRING  COMMENT '上架日期（缺失已按类目中位数补全）',
    launch_date_is_filled   INT     COMMENT '上架日期是否为补全值：1=补全 0=原始'
)
COMMENT '商品明细表-DWD层'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ----------------------------------------------------------------------------
-- 3. dwd_order —— 订单明细表（重复值去重）
--    相对 ODS 的变更：
--      order_id 唯一，15600 → 15000 行
--      新增 dedup_flag：标记该类订单在 ODS 中原本有几条（便于追溯重复程度）
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS dwd_order;
CREATE TABLE dwd_order (
    order_id        STRING  COMMENT '订单编号（已去重，唯一）',
    user_id         STRING  COMMENT '用户编号',
    store_id        STRING  COMMENT '门店编号',
    order_date      STRING  COMMENT '下单日期（格式统一属第2周）',
    order_time      STRING  COMMENT '下单时间',
    pay_amount      DOUBLE  COMMENT '实付金额（异常值处理属第2周）',
    discount_amount DOUBLE  COMMENT '优惠金额',
    pay_type        STRING  COMMENT '支付方式（枚举归一化属第2周）',
    order_status    STRING  COMMENT '订单状态（枚举归一化属第2周）',
    channel         STRING  COMMENT '下单渠道（枚举归一化属第2周）',
    ods_dup_cnt     INT     COMMENT '该订单在 ODS 层出现的行数：1=原本唯一 >1=曾重复'
)
COMMENT '订单明细表-DWD层（已去重）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- 建表结果确认
SHOW TABLES IN ydsh_dwd;
