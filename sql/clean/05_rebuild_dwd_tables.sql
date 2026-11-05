-- ============================================================================
-- 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统
-- 第 2 周 步骤 1：重建 DWD 层表结构 + 初始化码表维度
-- ----------------------------------------------------------------------------
-- 文件    : sql/clean/05_rebuild_dwd_tables.sql
-- 作者    : 张宇翔
-- 依赖    : ODS 层 6 张表已导入（第 1 周完成）
-- 执行    : beeline -u jdbc:hive2://localhost:10000 -f /sql/clean/05_rebuild_dwd_tables.sql
--
-- 【为什么第 2 周要「重建」而不是「增量改」】
--   第 1 周已把 age 的异常值（0/150/200/-3）用中位数填充完毕，DWD 里
--   已经看不到任何异常年龄（实测 age 区间 18~65，age_is_filled=78）。
--   若第 2 周仍在现有 DWD 上做"异常值修正"，将一条脏值都修不到，
--   数据质量对比报告也拿不到 before 数据。
--   因此第 2 周从 ODS 全量重算 DWD —— ODS 是不可变的唯一真相源，
--   DWD 随时可重算，重建不丢失任何原始数据。
--
-- 【为什么 dwd_user / dwd_product 改名为 dim_user / dim_product】
--   第 2 周任务书要求「以订单事实表 dwd_order 为核心，关联用户维度 dim_user、
--   商品维度 dim_product、门店维度 dim_store、时间维度 dim_date」，
--   即 DWD 层按 Kimball 星型模型区分「事实表 dwd_*」与「维度表 dim_*」。
--   第 1 周的 dwd_user / dwd_product 实为维度语义，第 2 周统一改为 dim_*，
--   字段基本保留（含第 1 周的可溯源标记），第 1 周文档描述仍然成立。
--
-- 【表清单】
--   维度表：dim_user / dim_product / dim_store / dim_date
--          + 三个枚举维度 dim_member_level / dim_pay_type / dim_order_status（主键=中文名，唯一）
--   映射表：map_member_level / map_pay_type / map_order_status（主键=src_value，仅 ETL 使用）
--   事实表：dwd_order（按年月分区） / dwd_order_item / dwd_user_behavior（按年月分区）
-- ============================================================================

USE ydsh_dwd;

-- ---------------------------------------------------------------------------
-- 0. 清理第 1 周遗留临时表
--    第 1 周做中位数填充时留下了 3 张 tmp_* 中间表，未清理会污染 DWD 命名空间。
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_age_median;
DROP TABLE IF EXISTS tmp_launch_global;
DROP TABLE IF EXISTS tmp_launch_median;

-- 第 1 周的三张表：语义并入 dim_*，此处删除后重建
DROP TABLE IF EXISTS dwd_user;
DROP TABLE IF EXISTS dwd_product;
DROP TABLE IF EXISTS dwd_order;
DROP TABLE IF EXISTS dim_user;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS dim_store;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_member_level;
DROP TABLE IF EXISTS dim_pay_type;
DROP TABLE IF EXISTS dim_order_status;
DROP TABLE IF EXISTS map_member_level;
DROP TABLE IF EXISTS map_pay_type;
DROP TABLE IF EXISTS map_order_status;
DROP TABLE IF EXISTS dwd_order_item;
DROP TABLE IF EXISTS dwd_user_behavior;

-- ===========================================================================
-- 一、枚举映射表与枚举维度表（两者分离，不可混用）
-- ---------------------------------------------------------------------------
-- 【第 2 周验收修正 · 为什么要拆】
--   原设计把「源值映射」与「维度」压在同一个 dim_* 表里：
--   dim_order_status 12 行中只有 5 个 status_name（已完成 / 已支付各 3 行），
--   dim_pay_type 9 行中只有 4 个 pay_name（微信支付 3 行）。
--   而事实表存的是中文名。按星型模型 join on status_name 时，
--   一条事实会被匹配 3 次 —— 实测 GMV 由 24,717,464.96 膨胀到 74,152,394.88（整 3 倍）。
--
--   维度表的主键必须唯一，因此拆成两类：
--     map_*  —— 映射表，主键 src_value（唯一），只服务 ETL，不进入星型模型
--     dim_*  —— 维度表，主键为中文名（唯一），供事实表 / 报表安全关联
--   事实表字段与数据均不变，无需重刷。
-- ---------------------------------------------------------------------------

-- 1.1 会员等级：映射表（12 种源值）+ 维度表（4 个标准等级）
CREATE TABLE map_member_level (
    src_value      STRING COMMENT '源取值（小写去空格后的脏值）',
    level_name     STRING COMMENT '标准等级名称',
    level_code     STRING COMMENT '等级编码',
    level_rank     INT    COMMENT '等级序号，1 最低',
    discount_rate  DOUBLE COMMENT '该等级默认折扣率'
)
COMMENT '会员等级源值映射表（ETL 专用，主键 src_value）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT INTO map_member_level VALUES
('普通会员', '普通会员', 'L1', 1, 1.00),
('普通',     '普通会员', 'L1', 1, 1.00),
('normal',   '普通会员', 'L1', 1, 1.00),
('银卡会员', '银卡会员', 'L2', 2, 0.98),
('银卡',     '银卡会员', 'L2', 2, 0.98),
('silver',   '银卡会员', 'L2', 2, 0.98),
('金卡会员', '金卡会员', 'L3', 3, 0.95),
('金卡',     '金卡会员', 'L3', 3, 0.95),
('gold',     '金卡会员', 'L3', 3, 0.95),
('钻石会员', '钻石会员', 'L4', 4, 0.90),
('钻石',     '钻石会员', 'L4', 4, 0.90),
('diamond',  '钻石会员', 'L4', 4, 0.90);

CREATE TABLE dim_member_level (
    level_name     STRING COMMENT '标准等级名称（主键）',
    level_code     STRING COMMENT '等级编码',
    level_rank     INT    COMMENT '等级序号，1 最低',
    discount_rate  DOUBLE COMMENT '该等级默认折扣率'
)
COMMENT '会员等级维度表（主键 level_name，一名一行）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT INTO dim_member_level VALUES
('普通会员', 'L1', 1, 1.00),
('银卡会员', 'L2', 2, 0.98),
('金卡会员', 'L3', 3, 0.95),
('钻石会员', 'L4', 4, 0.90);

-- 1.2 支付方式：映射表（9 种源值）+ 维度表（4 个标准值）
CREATE TABLE map_pay_type (
    src_value  STRING COMMENT '源取值（小写去空格）',
    pay_name   STRING COMMENT '标准支付方式',
    pay_code   STRING COMMENT '支付方式编码',
    is_online  INT    COMMENT '是否线上支付：1=是 0=否'
)
COMMENT '支付方式源值映射表（ETL 专用，主键 src_value）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT INTO map_pay_type VALUES
('支付宝',   '支付宝',   'ALIPAY', 1),
('alipay',   '支付宝',   'ALIPAY', 1),
('微信支付', '微信支付', 'WECHAT', 1),
('微信',     '微信支付', 'WECHAT', 1),
('wechat',   '微信支付', 'WECHAT', 1),
('银行卡',   '银行卡',   'BANK',   1),
('bank',     '银行卡',   'BANK',   1),
('货到付款', '货到付款', 'COD',    0),
('cod',      '货到付款', 'COD',    0);

CREATE TABLE dim_pay_type (
    pay_name   STRING COMMENT '标准支付方式（主键）',
    pay_code   STRING COMMENT '支付方式编码',
    is_online  INT    COMMENT '是否线上支付：1=是 0=否'
)
COMMENT '支付方式维度表（主键 pay_name，一名一行）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT INTO dim_pay_type VALUES
('支付宝',   'ALIPAY', 1),
('微信支付', 'WECHAT', 1),
('银行卡',   'BANK',   1),
('货到付款', 'COD',    0);

-- 1.3 订单状态：映射表（12 种源值）+ 维度表（5 个标准状态）
--     is_gmv_included 是 GMV 口径的关键：已取消 / 退款中 / 待支付 不计入 GMV。
--     任务书手册未定义该口径，直接 sum(pay_amount) 会虚增 GMV，此处显式建模。
CREATE TABLE map_order_status (
    src_value       STRING COMMENT '源取值（小写去空格）',
    status_name     STRING COMMENT '标准状态名称',
    status_code     STRING COMMENT '状态编码',
    is_gmv_included INT    COMMENT '是否计入 GMV：1=计入 0=不计入',
    is_final        INT    COMMENT '是否为终态：1=终态 0=流转中'
)
COMMENT '订单状态源值映射表（ETL 专用，主键 src_value）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT INTO map_order_status VALUES
('待支付',  '待支付', 'PENDING',   0, 0),
('1',        '待支付', 'PENDING',   0, 0),
('已支付',  '已支付', 'PAID',      1, 0),
('已付款',  '已支付', 'PAID',      1, 0),
('2',        '已支付', 'PAID',      1, 0),
('已完成',  '已完成', 'COMPLETED', 1, 1),
('完成',    '已完成', 'COMPLETED', 1, 1),
('3',        '已完成', 'COMPLETED', 1, 1),
('已取消',  '已取消', 'CANCELLED', 0, 1),
('cancelled','已取消', 'CANCELLED', 0, 1),
('4',        '已取消', 'CANCELLED', 0, 1),
('退款中',  '退款中', 'REFUNDING', 0, 0);

CREATE TABLE dim_order_status (
    status_name     STRING COMMENT '标准状态名称（主键）',
    status_code     STRING COMMENT '状态编码',
    is_gmv_included INT    COMMENT '是否计入 GMV：1=计入 0=不计入',
    is_final        INT    COMMENT '是否为终态：1=终态 0=流转中'
)
COMMENT '订单状态维度表（主键 status_name，一名一行）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT INTO dim_order_status VALUES
('待支付', 'PENDING',   0, 0),
('已支付', 'PAID',      1, 0),
('已完成', 'COMPLETED', 1, 1),
('已取消', 'CANCELLED', 0, 1),
('退款中', 'REFUNDING', 0, 0);

-- ===========================================================================
-- 二、业务维度表
-- ===========================================================================

-- 2.1 用户维度
CREATE TABLE dim_user (
    user_id        STRING COMMENT '用户编号',
    user_name      STRING COMMENT '用户姓名',
    gender         STRING COMMENT '性别（已标准化：男/女/未知）',
    age            INT    COMMENT '年龄（异常值已置空并按中位数填充）',
    age_is_filled  INT    COMMENT '年龄是否为填充值：1=填充 0=原始',
    city           STRING COMMENT '城市',
    province       STRING COMMENT '省份',
    region         STRING COMMENT '地区（省-市，字段合并）',
    register_date  STRING COMMENT '注册日期（已统一为 yyyy-MM-dd）',
    member_level   STRING COMMENT '会员等级（已标准化为中文标准值）',
    level_rank     INT    COMMENT '会员等级序号（关联码表得到）',
    phone          STRING COMMENT '手机号（已统一为 11 位纯数字）',
    email          STRING COMMENT '邮箱（允许为空）',
    email_is_null  INT    COMMENT '邮箱是否缺失：1=缺失 0=有值'
)
COMMENT '用户维度表-DWD层'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- 2.2 商品维度
CREATE TABLE dim_product (
    product_id            STRING COMMENT '商品编号',
    product_name          STRING COMMENT '商品名称',
    category              STRING COMMENT '一级类目（已去首尾空格）',
    sub_category          STRING COMMENT '二级类目（已去首尾空格）',
    brand                 STRING COMMENT '品牌（已统一大小写与空格）',
    price                 DOUBLE COMMENT '售价（负数取绝对值，超大值置空）',
    price_is_fixed        INT    COMMENT '售价是否被修正：1=修正 0=原始',
    cost                  DOUBLE COMMENT '成本价',
    stock                 INT    COMMENT '库存数量',
    status                STRING COMMENT '状态',
    launch_date           STRING COMMENT '上架日期（已统一 yyyy-MM-dd，缺失已补全）',
    launch_date_is_filled INT    COMMENT '上架日期是否为补全值：1=补全 0=原始'
)
COMMENT '商品维度表-DWD层'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- 2.3 门店维度
CREATE TABLE dim_store (
    store_id    STRING COMMENT '门店编号',
    store_name  STRING COMMENT '门店名称',
    province    STRING COMMENT '省份',
    city        STRING COMMENT '城市',
    district    STRING COMMENT '区县',
    address     STRING COMMENT '详细地址',
    region      STRING COMMENT '地区（省-市，字段合并）',
    open_date   STRING COMMENT '开业日期（统一 yyyy-MM-dd）',
    area        INT    COMMENT '营业面积（㎡）',
    manager     STRING COMMENT '店长姓名'
)
COMMENT '门店维度表-DWD层'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- 2.4 时间维度（2024 全年，由脚本生成，无源表）
CREATE TABLE dim_date (
    date_key        STRING COMMENT '日期主键 yyyy-MM-dd',
    year            INT    COMMENT '年',
    quarter         INT    COMMENT '季度 1-4',
    month           INT    COMMENT '月 1-12',
    day             INT    COMMENT '日',
    week_of_year    INT    COMMENT '当年第几周',
    day_of_week     INT    COMMENT '星期几：1=周一 … 7=周日',
    is_weekend      INT    COMMENT '是否周末：1=是 0=否',
    year_month      STRING COMMENT '年月 yyyy-MM'
)
COMMENT '时间维度表-DWD层'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- ===========================================================================
-- 三、事实表
-- ===========================================================================

-- 3.1 订单事实表（按年月分区）
--     任务书建议按 order_date 按天分区；实测数据跨 2024 年 1~9 月，
--     按天分区会产生 250+ 个小分区、Tez 下小文件过多反而拖慢查询。
--     故采用「按年月分区」（9 个分区），兼顾分区裁剪与文件数。
CREATE TABLE dwd_order (
    order_id         STRING COMMENT '订单编号（已去重，唯一）',
    user_id          STRING COMMENT '用户编号',
    store_id         STRING COMMENT '门店编号',
    order_date       STRING COMMENT '下单日期（已统一 yyyy-MM-dd）',
    order_time       STRING COMMENT '下单时间（已统一 HH:mm:ss）',
    order_timestamp  STRING COMMENT '下单时间戳（date+time 合并，yyyy-MM-dd HH:mm:ss）',
    pay_amount       DOUBLE COMMENT '实付金额（负数取绝对值，超大值置空）',
    discount_amount  DOUBLE COMMENT '优惠金额',
    pay_type         STRING COMMENT '支付方式（已标准化）',
    order_status     STRING COMMENT '订单状态（已标准化）',
    is_gmv_included  INT    COMMENT '是否计入 GMV（关联状态码表得到）',
    channel          STRING COMMENT '下单渠道（已标准化）',
    ods_dup_cnt      INT    COMMENT '该订单在 ODS 层出现的行数：1=原本唯一 >1=曾重复',
    amt_fix_flag     INT    COMMENT '金额修正标记：0=原始 1=负数取绝对值 2=置空'
)
COMMENT '订单事实表-DWD层（已去重、已标准化、按年月分区）'
PARTITIONED BY (order_ym STRING COMMENT '订单年月 yyyy-MM')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- 3.2 订单明细事实表
CREATE TABLE dwd_order_item (
    item_id      STRING COMMENT '明细编号',
    order_id     STRING COMMENT '所属订单编号',
    product_id   STRING COMMENT '商品编号',
    quantity     INT    COMMENT '购买数量（0/负数/超大值已置空）',
    qty_is_fixed INT    COMMENT '数量是否被修正：1=修正 0=原始',
    unit_price   DOUBLE COMMENT '商品单价',
    discount     DOUBLE COMMENT '折扣率 0~1',
    item_amount  DOUBLE COMMENT '明细金额 = quantity*unit_price*(1-discount)'
)
COMMENT '订单明细事实表-DWD层'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- 3.3 用户行为事实表（按年月分区）
CREATE TABLE dwd_user_behavior (
    behavior_id    STRING COMMENT '行为编号',
    user_id        STRING COMMENT '用户编号',
    product_id     STRING COMMENT '商品编号',
    behavior_type  STRING COMMENT '行为类型（已标准化：pv/cart/fav/buy）',
    behavior_time  STRING COMMENT '行为时间（已统一 yyyy-MM-dd HH:mm:ss）',
    behavior_date  STRING COMMENT '行为日期 yyyy-MM-dd',
    session_id     STRING COMMENT '会话编号'
)
COMMENT '用户行为事实表-DWD层（按年月分区）'
PARTITIONED BY (behavior_ym STRING COMMENT '行为年月 yyyy-MM')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- 建表结果确认
SHOW TABLES IN ydsh_dwd;
