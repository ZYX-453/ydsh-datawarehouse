-- ============================================================================
-- 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统
-- ODS 贴源层建表脚本（6 张业务表）
-- ----------------------------------------------------------------------------
-- 文件    : sql/ods/02_create_ods_tables.sql
-- 作者    : 张宇翔
-- 依赖    : 先执行 01_create_database.sql
-- 执行    : beeline -u jdbc:hive2://localhost:10000 -f 02_create_ods_tables.sql
--
-- 设计说明（重要，答辩会问）：
--   1) 贴源层原则：字段类型与清洗规则均不做业务加工，只做结构与格式对齐，
--      保留全部脏数据，便于后续做"清洗前/后"数据质量对比。
--   2) 【CRLF 陷阱】源 CSV 为 Windows CRLF 换行（已实测 6 张表全部 CRLF）。
--      若写成 LINES TERMINATED BY '\n'，每行最后一个字段会带上 '\r'，
--      导致 channel 变成 'APP\r'、枚举分组全部错位。故此处统一写 '\r\n'。
--   3) 【BOM 陷阱】源 CSV 为 UTF-8 BOM 编码，BOM 位于第 1 行（表头）行首。
--      建表使用 skip.header.line.count=1 跳过表头时，BOM 随之被跳过，
--      因此首字段不会残留 '\ufeff'。导入后需用查询验证，见 03 脚本末尾。
--   4) 字段分隔符统一为英文逗号 ','。源文件已实测：无引号包裹、无中文逗号、
--      无制表符、每行字段数与表头完全一致，故无需 OpenCSVSerde。
-- ============================================================================

USE ydsh_ods;

-- ----------------------------------------------------------------------------
-- 1. ods_user —— 用户信息表（1000 行）
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS ods_user;
CREATE TABLE ods_user (
    user_id        STRING  COMMENT '用户编号（主键）',
    user_name      STRING  COMMENT '用户姓名',
    gender         STRING  COMMENT '性别（含异常值：男/女/M/F/male/female/未知/空）',
    age            INT     COMMENT '年龄（含缺失、异常：空/-3/0/150/200）',
    city           STRING  COMMENT '城市',
    province       STRING  COMMENT '省份',
    register_date  STRING  COMMENT '注册日期（格式不一致：2023-11-25 / 2023/11/25 / 20231125）',
    member_level   STRING  COMMENT '会员等级（中英文混用：金卡/金卡会员/gold/普通/normal/空）',
    phone          STRING  COMMENT '手机号（格式不一致：13892127520 / 138-9212-7520）',
    email          STRING  COMMENT '邮箱（部分缺失）'
)
COMMENT '用户信息表-ODS贴源层'
ROW FORMAT DELIMITED
    FIELDS TERMINATED BY ','
    LINES TERMINATED BY '\r\n'
STORED AS TEXTFILE
TBLPROPERTIES (
    'skip.header.line.count' = '1',
    'serialization.encoding' = 'UTF-8'
);

-- ----------------------------------------------------------------------------
-- 2. ods_product —— 商品信息表（600 行）
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS ods_product;
CREATE TABLE ods_product (
    product_id     STRING  COMMENT '商品编号（主键）',
    product_name   STRING  COMMENT '商品名称',
    category       STRING  COMMENT '一级类目（含首尾空格异常，8 类共 16 种取值）',
    sub_category   STRING  COMMENT '二级类目',
    brand          STRING  COMMENT '品牌（大小写异常）',
    price          DOUBLE  COMMENT '售价（含负数、异常高价 999999 级）',
    cost           DOUBLE  COMMENT '成本价',
    stock          INT     COMMENT '库存数量',
    status         STRING  COMMENT '状态（在售/下架/缺货）',
    launch_date    STRING  COMMENT '上架日期（部分缺失）'
)
COMMENT '商品信息表-ODS贴源层'
ROW FORMAT DELIMITED
    FIELDS TERMINATED BY ','
    LINES TERMINATED BY '\r\n'
STORED AS TEXTFILE
TBLPROPERTIES (
    'skip.header.line.count' = '1',
    'serialization.encoding' = 'UTF-8'
);

-- ----------------------------------------------------------------------------
-- 3. ods_store —— 门店信息表（60 行）
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS ods_store;
CREATE TABLE ods_store (
    store_id       STRING  COMMENT '门店编号（主键）',
    store_name     STRING  COMMENT '门店名称',
    province       STRING  COMMENT '省份',
    city           STRING  COMMENT '城市',
    district       STRING  COMMENT '区县',
    address        STRING  COMMENT '详细地址',
    open_date      STRING  COMMENT '开业日期',
    area           INT     COMMENT '营业面积（㎡）',
    manager        STRING  COMMENT '店长姓名'
)
COMMENT '门店信息表-ODS贴源层'
ROW FORMAT DELIMITED
    FIELDS TERMINATED BY ','
    LINES TERMINATED BY '\r\n'
STORED AS TEXTFILE
TBLPROPERTIES (
    'skip.header.line.count' = '1',
    'serialization.encoding' = 'UTF-8'
);

-- ----------------------------------------------------------------------------
-- 4. ods_order —— 订单主表（15600 行，含约 600 行重复）
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS ods_order;
CREATE TABLE ods_order (
    order_id        STRING  COMMENT '订单编号（应唯一，含重复）',
    user_id         STRING  COMMENT '用户编号',
    store_id        STRING  COMMENT '门店编号',
    order_date      STRING  COMMENT '下单日期（实测 100% 斜杠格式 2024/7/26）',
    order_time      STRING  COMMENT '下单时间',
    pay_amount      DOUBLE  COMMENT '实付金额（含负数、百万级异常值）',
    discount_amount DOUBLE  COMMENT '优惠金额',
    pay_type        STRING  COMMENT '支付方式（中英文混用：微信支付/微信/wechat/alipay/alipay…）',
    order_status    STRING  COMMENT '订单状态（取值不规范：已完成/完成/1/2/3/4/cancelled…）',
    channel         STRING  COMMENT '下单渠道（大小写混用：APP/app/PC官网/pc/门店/小程序）'
)
COMMENT '订单主表-ODS贴源层'
ROW FORMAT DELIMITED
    FIELDS TERMINATED BY ','
    LINES TERMINATED BY '\r\n'
STORED AS TEXTFILE
TBLPROPERTIES (
    'skip.header.line.count' = '1',
    'serialization.encoding' = 'UTF-8'
);

-- ----------------------------------------------------------------------------
-- 5. ods_order_item —— 订单明细表（37549 行）
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS ods_order_item;
CREATE TABLE ods_order_item (
    item_id        STRING  COMMENT '明细编号（主键）',
    order_id       STRING  COMMENT '所属订单编号',
    product_id     STRING  COMMENT '商品编号',
    quantity       INT     COMMENT '购买数量（含 0、负数、超大值 99）',
    unit_price     DOUBLE  COMMENT '商品单价（含 0 与负值）',
    discount       DOUBLE  COMMENT '折扣率（0～1）'
)
COMMENT '订单明细表-ODS贴源层'
ROW FORMAT DELIMITED
    FIELDS TERMINATED BY ','
    LINES TERMINATED BY '\r\n'
STORED AS TEXTFILE
TBLPROPERTIES (
    'skip.header.line.count' = '1',
    'serialization.encoding' = 'UTF-8'
);

-- ----------------------------------------------------------------------------
-- 6. ods_user_behavior —— 用户行为日志表（60000 行）
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS ods_user_behavior;
CREATE TABLE ods_user_behavior (
    behavior_id    STRING  COMMENT '行为编号（主键）',
    user_id        STRING  COMMENT '用户编号',
    product_id     STRING  COMMENT '商品编号',
    behavior_type  STRING  COMMENT '行为类型（中英文混用：pv/PV/浏览、cart/Cart/加购、fav/收藏、buy/购买）',
    behavior_time  STRING  COMMENT '行为发生时间（格式不一致）',
    session_id     STRING  COMMENT '会话编号'
)
COMMENT '用户行为日志表-ODS贴源层'
ROW FORMAT DELIMITED
    FIELDS TERMINATED BY ','
    LINES TERMINATED BY '\r\n'
STORED AS TEXTFILE
TBLPROPERTIES (
    'skip.header.line.count' = '1',
    'serialization.encoding' = 'UTF-8'
);

-- ----------------------------------------------------------------------------
-- 建表结果确认
-- ----------------------------------------------------------------------------
SHOW TABLES IN ydsh_ods;
DESC ods_user;
