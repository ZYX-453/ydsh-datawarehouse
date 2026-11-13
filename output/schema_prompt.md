### 可用数据表（Hive）

**ads_behavior_funnel**（库 ydsh_ads）— 无表注释
  - step int  漏斗层级 1=浏览 2=收藏 3=加购 4=购买
  - behavior_type string  行为类型 pv/fav/cart/buy
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'buy'、'cart'、'fav'、'pv'
  - event_cnt bigint  行为事件数
  - user_cnt bigint  涉及用户数
  - event_share double  事件占比（相对浏览）

**ads_category_rank**（库 ydsh_ads）— 无表注释
  - rk int  销售额排名
  - category string  一级类目
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'运动户外'、'数码家电'、'服饰鞋包'、'图书文娱'、'食品生鲜'、'家居生活'、'美妆个护'、'母婴玩具'
  - sales_amt double  销售额（订单实付按明细占比分摊后归集）
  - sales_share double  销售额占比
  - order_cnt bigint  涉及订单数
  - qty bigint  销售件数
  - aov double  笔单价 = sales_amt / order_cnt
  - brand_cnt bigint  在售品牌数

**ads_kpi_month**（库 ydsh_ads）— 无表注释
  - stat_ym string  统计年月 yyyy-MM
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'2024-01'、'2024-02'、'2024-03'、'2024-04'、'2024-05'、'2024-06'、'2024-07'、'2024-08'、'2024-09'、'2024-10'、'2024-11'、'2024-12'
  - gmv double  GMV
  - order_cnt bigint  订单量
  - aov double  客单价
  - user_cnt bigint  成交用户数
  - repurchase_rate double  当月复购率 = 当月成交 >=2 单用户 / 当月成交用户
  - gmv_mom double  GMV 环比 = (本月 - 上月) / 上月
  - order_mom double  订单量环比

**ads_kpi_overview**（库 ydsh_ads）— 无表注释
  - stat_scope string  统计口径范围，如 2024 全年
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'2024 全年（成交口径）'
  - gmv double  GMV 成交总额
  - order_cnt bigint  订单量（去重）
  - aov double  客单价 = gmv / order_cnt
  - active_users bigint  活跃（成交）用户数
  - order_users bigint  下单用户数（与活跃用户同口径，用于复购率分母）
  - repurchase_users bigint  复购用户数（成交 >= 2 单）
  - repurchase_rate double  复购率 = 复购用户 / 下单用户
  - item_qty bigint  成交件数
  - discount_amt double  优惠金额合计
  - discount_rate double  优惠率 = 优惠金额 / (GMV + 优惠金额)
  - avg_month_gmv double  月均 GMV

**ads_region_rank**（库 ydsh_ads）— 无表注释
  - rk int  GMV 排名
  - province string  省份
  - gmv double  GMV
  - gmv_share double  GMV 占比
  - order_cnt bigint  订单量
  - user_cnt bigint  成交用户数
  - store_cnt bigint  门店数
  - aov double  客单价

**ads_sales_daily**（库 ydsh_ads）— 无表注释
  - stat_date string  日期 yyyy-MM-dd
  - gmv double  当日 GMV
  - order_cnt bigint  当日订单量
  - user_cnt bigint  当日成交用户数
  - aov double  当日客单价
  - ma7 double  7 日移动平均 GMV（不足 7 天取已有天数）
  - weekday int  星期几 1=周一 ... 7=周日

**ads_store_top10**（库 ydsh_ads）— 无表注释
  - rk int  GMV 排名
  - store_id string  门店编号
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'S029'、'S012'、'S056'、'S031'、'S009'、'S025'、'S028'、'S002'、'S037'、'S015'
  - store_name string  门店名称
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'云购生活·青岛二店'、'云购生活·北京二店'、'云购生活·绍兴旗舰店'、'云购生活·开封社区店'、'云购生活·嘉兴社区店'、'云购生活·莆田旗舰店'、'云购生活·苏州旗舰店'、'云购生活·合肥购物中心店'、'云购生活·南通社区店'
  - province string  省份
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'浙江省'、'江苏省'、'山东省'、'北京市'、'河南省'、'福建省'、'安徽省'
  - city string  城市
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'青岛'、'北京'、'绍兴'、'开封'、'嘉兴'、'莆田'、'苏州'、'合肥'、'南通'
  - gmv double  GMV
  - order_cnt bigint  订单量
  - aov double  客单价

**ads_user_value**（库 ydsh_ads）— 无表注释
  - segment string  RFM 客户分层名称
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'一般价值客户'、'一般保持客户'、'一般发展客户'、'一般挽留客户'、'重要价值客户'、'重要保持客户'、'重要发展客户'、'重要挽留客户'
  - user_cnt bigint  用户数
  - user_share double  用户占比
  - gmv double  该层 GMV
  - gmv_share double  GMV 占比
  - avg_gmv double  人均消费
  - avg_orders double  人均订单数
  - avg_recency double  平均 R 值（末单距 2024-12-31 天数）

**dim_date**（库 ydsh_dwd）— 无表注释
  - date_key string  日期主键 yyyy-MM-dd
  - year int  年
  - quarter int  季度 1-4
  - month int  月 1-12
  - day int  日
  - week_of_year int  当年第几周
  - day_of_week int  星期几：1=周一 … 7=周日
  - is_weekend int  是否周末：1=是 0=否
  - year_month string  年月 yyyy-MM
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'2024-01'、'2024-03'、'2024-05'、'2024-07'、'2024-08'、'2024-10'、'2024-12'、'2024-04'、'2024-06'、'2024-09'、'2024-11'、'2024-02'

**dim_member_level**（库 ydsh_dwd）— 无表注释
  - level_name string  标准等级名称（主键）
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'普通会员'、'银卡会员'、'金卡会员'、'钻石会员'
  - level_code string  等级编码
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'L1'、'L2'、'L3'、'L4'
  - level_rank int  等级序号，1 最低
  - discount_rate double  该等级默认折扣率

**dim_order_status**（库 ydsh_dwd）— 无表注释
  - status_name string  标准状态名称（主键）
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'待支付'、'已支付'、'已完成'、'已取消'、'退款中'
  - status_code string  状态编码
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'PENDING'、'PAID'、'COMPLETED'、'CANCELLED'、'REFUNDING'
  - is_gmv_included int  是否计入 GMV：1=计入 0=不计入
  - is_final int  是否为终态：1=终态 0=流转中

**dim_pay_type**（库 ydsh_dwd）— 无表注释
  - pay_name string  标准支付方式（主键）
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'支付宝'、'微信支付'、'银行卡'、'货到付款'
  - pay_code string  支付方式编码
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'ALIPAY'、'WECHAT'、'BANK'、'COD'
  - is_online int  是否线上支付：1=是 0=否

**dim_product**（库 ydsh_dwd）— 无表注释
  - product_id string  商品编号
  - product_name string  商品名称
  - category string  一级类目（已去首尾空格）
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'运动户外'、'数码家电'、'图书文娱'、'服饰鞋包'、'食品生鲜'、'家居生活'、'美妆个护'、'母婴玩具'
  - sub_category string  二级类目（已去首尾空格）
  - brand string  品牌（已统一大小写与空格）
  - price double  售价（负数取绝对值，超大值置空）
  - price_is_fixed int  售价是否被修正：1=修正 0=原始
  - cost double  成本价
  - stock int  库存数量
  - status string  状态
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'在售'、'下架'、'缺货'
  - launch_date string  上架日期（已统一 yyyy-MM-dd，缺失已补全）
  - launch_date_is_filled int  上架日期是否为补全值：1=补全 0=原始

**dim_store**（库 ydsh_dwd）— 无表注释
  - store_id string  门店编号
  - store_name string  门店名称
  - province string  省份
  - city string  城市
  - district string  区县
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'开发区'、'新区'、'老城区'、'中心区'、'高新区'、'滨江区'
  - address string  详细地址
  - region string  地区（省-市，字段合并）
  - open_date string  开业日期（统一 yyyy-MM-dd）
  - area int  营业面积（㎡）
  - manager string  店长姓名

**dim_user**（库 ydsh_dwd）— 无表注释
  - user_id string  用户编号
  - user_name string  用户姓名
  - gender string  性别（已标准化：男/女/未知）
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'女'、'男'、'未知'
  - age int  年龄（异常值已置空并按中位数填充）
  - age_is_filled int  年龄是否为填充值：1=填充 0=原始
  - city string  城市
  - province string  省份
  - region string  地区（省-市，字段合并）
  - register_date string  注册日期（已统一为 yyyy-MM-dd）
  - member_level string  会员等级（已标准化为中文标准值）
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'金卡会员'、'钻石会员'、'普通会员'、'银卡会员'
  - level_rank int  会员等级序号（关联码表得到）
  - phone string  手机号（已统一为 11 位纯数字）
  - email string  邮箱（允许为空）
  - email_is_null int  邮箱是否缺失：1=缺失 0=有值

**dwd_order**（库 ydsh_dwd）— 无表注释
  - order_id string  订单编号（已去重，唯一）
  - user_id string  用户编号
  - store_id string  门店编号
  - order_date string  下单日期（已统一 yyyy-MM-dd）
  - order_time string  下单时间（已统一 HH:mm:ss）
  - order_timestamp string  下单时间戳（date+time 合并，yyyy-MM-dd HH:mm:ss）
  - pay_amount double  实付金额（负数取绝对值，超大值置空）
  - discount_amount double  优惠金额
  - pay_type string  支付方式（已标准化）
  - order_status string  订单状态（已标准化）
  - is_gmv_included int  是否计入 GMV（关联状态码表得到）
  - channel string  下单渠道（已标准化）
  - ods_dup_cnt int  该订单在 ODS 层出现的行数：1=原本唯一 >1=曾重复
  - amt_fix_flag int  金额修正标记：0=原始 1=负数取绝对值 2=置空
  - order_ym string  订单年月 yyyy-MM
  - order_ym string  订单年月 yyyy-MM [分区键]

**dwd_order_item**（库 ydsh_dwd）— 无表注释
  - item_id string  明细编号
  - order_id string  所属订单编号
  - product_id string  商品编号
  - quantity int  购买数量（0/负数/超大值已置空）
  - qty_is_fixed int  数量是否被修正：1=修正 0=原始
  - unit_price double  商品单价
  - discount double  折扣率 0~1
  - item_amount double  明细金额 = quantity*unit_price*(1-discount)

**dwd_user_behavior**（库 ydsh_dwd）— 无表注释
  - behavior_id string  行为编号
  - user_id string  用户编号
  - product_id string  商品编号
  - behavior_type string  行为类型（已标准化：pv/cart/fav/buy）
  - behavior_time string  行为时间（已统一 yyyy-MM-dd HH:mm:ss）
  - behavior_date string  行为日期 yyyy-MM-dd
  - session_id string  会话编号
  - behavior_ym string  行为年月 yyyy-MM
  - behavior_ym string  行为年月 yyyy-MM [分区键]

**map_member_level**（库 ydsh_dwd）— 无表注释
  - src_value string  源取值（小写去空格后的脏值）
  - level_name string  标准等级名称
  - level_code string  等级编码
  - level_rank int  等级序号，1 最低
  - discount_rate double  该等级默认折扣率

**map_order_status**（库 ydsh_dwd）— 无表注释
  - src_value string  源取值（小写去空格）
  - status_name string  标准状态名称
  - status_code string  状态编码
  - is_gmv_included int  是否计入 GMV：1=计入 0=不计入
  - is_final int  是否为终态：1=终态 0=流转中

**map_pay_type**（库 ydsh_dwd）— 无表注释
  - src_value string  源取值（小写去空格）
  - pay_name string  标准支付方式
  - pay_code string  支付方式编码
  - is_online int  是否线上支付：1=是 0=否

**dws_product_month**（库 ydsh_dws）— 无表注释
  - product_id string  商品编号
  - product_name string  商品名称
  - category string  一级类目
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'运动户外'、'数码家电'、'图书文娱'、'服饰鞋包'、'食品生鲜'、'家居生活'、'美妆个护'、'母婴玩具'
  - sub_category string  二级类目
  - brand string  品牌
  - qty bigint  销售件数
  - sales_amt double  销售额（明细金额之和）
  - order_cnt bigint  涉及订单数（去重）
  - cost_amt double  成本额 = 件数 × 成本价（用于毛利测算）
  - stat_ym string  统计年月 yyyy-MM
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'2024-01'、'2024-12'、'2024-05'、'2024-10'、'2024-08'、'2024-07'、'2024-11'、'2024-03'、'2024-04'、'2024-09'、'2024-06'、'2024-02'
  - stat_ym string  统计年月 yyyy-MM [分区键]
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'2024-01'、'2024-12'、'2024-05'、'2024-10'、'2024-08'、'2024-07'、'2024-11'、'2024-03'、'2024-04'、'2024-09'、'2024-06'、'2024-02'

**dws_store_month**（库 ydsh_dws）— 无表注释
  - store_id string  门店编号
  - store_name string  门店名称
  - province string  省份
  - city string  城市
  - gmv double  成交金额
  - order_cnt bigint  成交订单数
  - user_cnt bigint  成交用户数
  - aov double  客单价 = gmv / order_cnt
  - stat_ym string  统计年月 yyyy-MM
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'2024-01'、'2024-02'、'2024-03'、'2024-04'、'2024-05'、'2024-06'、'2024-07'、'2024-08'、'2024-09'、'2024-10'、'2024-11'、'2024-12'
  - stat_ym string  统计年月 yyyy-MM [分区键]
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'2024-01'、'2024-02'、'2024-03'、'2024-04'、'2024-05'、'2024-06'、'2024-07'、'2024-08'、'2024-09'、'2024-10'、'2024-11'、'2024-12'

**dws_trade_day**（库 ydsh_dws）— 无表注释
  - stat_date string  统计日期 yyyy-MM-dd
  - channel string  下单渠道（已标准化）
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'门店'、'APP'、'PC官网'、'小程序'
  - gmv double  成交金额（is_gmv_included=1 的实付金额之和）
  - order_cnt bigint  成交订单数（去重）
  - user_cnt bigint  成交用户数（去重）
  - discount_amt double  优惠金额合计
  - item_qty bigint  成交商品件数（来自订单明细）
  - stat_ym string  统计年月 yyyy-MM
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'2024-03'、'2024-05'、'2024-07'、'2024-08'、'2024-10'、'2024-12'、'2024-01'、'2024-04'、'2024-06'、'2024-09'、'2024-11'、'2024-02'
  - stat_ym string  统计年月 yyyy-MM [分区键]
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'2024-03'、'2024-05'、'2024-07'、'2024-08'、'2024-10'、'2024-12'、'2024-01'、'2024-04'、'2024-06'、'2024-09'、'2024-11'、'2024-02'

**dws_trade_week**（库 ydsh_dws）— 无表注释
  - week_start string  周首日 yyyy-MM-dd（周一）
  - week_end string  周末日 yyyy-MM-dd（周日）
  - channel string  下单渠道
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'APP'、'PC官网'、'小程序'、'门店'
  - gmv double  成交金额
  - order_cnt bigint  成交订单数
  - user_cnt bigint  成交用户数
  - aov double  客单价 = gmv / order_cnt

**dws_user_agg**（库 ydsh_dws）— 无表注释
  - user_id string  用户编号
  - user_name string  用户姓名
  - member_level string  会员等级（中文标准值）
      ※ 该列实际取值（必须原样使用，勿改写或简写）：'金卡会员'、'钻石会员'、'普通会员'、'银卡会员'
  - province string  省份
  - city string  城市
  - first_order_date string  首单日期 yyyy-MM-dd
  - last_order_date string  末单日期 yyyy-MM-dd
  - order_cnt bigint  成交订单数
  - total_gmv double  累计成交金额
  - avg_order_amt double  笔单价 = total_gmv / order_cnt
  - active_months bigint  有成交的月份数（活跃月数）
  - r_value int  R 分位：末单距 2024-12-31 的天数
  - f_value bigint  F 值：成交订单数
  - m_value double  M 值：累计成交金额
