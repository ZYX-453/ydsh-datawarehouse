# 云购生活新零售企业 —— 企业级数据仓库与经营分析可视化系统

> 课程：企业项目实战实训 ｜ 数据科学与大数据技术（本科）
> 项目类型：从 0 到 1 端到端数据仓库与 BI 系统交付

---

## 一、项目简介

云购生活（虚构）是一家全国连锁的新零售企业，采用「线上商城 + 线下门店」融合经营模式，业务覆盖 15 个省份 / 直辖市，拥有 60 家线下门店，主营数码家电、服饰鞋包、食品生鲜、美妆个护、家居生活、母婴玩具、运动户外、图书文娱八大品类。

本项目针对企业数据分散、脏数据多、缺乏统一分析口径的痛点，搭建一套**企业级数据仓库与经营分析可视化系统**，实现从数据采集、清洗、分层建模、指标计算、预测分析到可视化呈现的完整链路。

---

## 二、团队成员与角色分工

> 说明：本项目为**个人独立完成**（任务书建议 3～4 人团队），以下按任务书要求的四类角色由本人**一人多岗**承担，全流程独立交付。

| 项目角色 | 承担人 | 主要职责 |
|---|---|---|
| 项目经理（兼数仓工程师） | 张宇翔 | 统筹进度、需求分析、数仓架构设计、Git 分支与版本管理 |
| 数据工程师 | 张宇翔 | 数据导入、数据清洗、Hive 四层建模与 ETL 脚本开发 |
| 数据分析师 / AI 工程师 | 张宇翔 | 探索性分析、预测建模、NL2SQL 与 AI 集成 |
| 可视化 / 部署工程师 | 张宇翔 | Superset 仪表板、ECharts 大屏、Docker 部署、文档编写 |

- **姓名**：张宇翔
- **专业**：数据科学与大数据技术
- **独立完成说明**：承担全部角色职责，无外部协作依赖

---

## 三、项目目标

按六层架构交付，每层对应明确的可验收产出：

| 层级 | 目标 | 关键产出 |
|---|---|---|
| 数据层 | 完成 6 张业务表采集导入，识别并清洗五类脏数据 | 清洗前后数据质量对比报告 |
| 数仓层 | 使用 Hive 搭建 ODS → DWD → DWS → ADS 四层数仓 | 维度建模 + ETL 全流程脚本 |
| 分析层 | 基于 ADS 层完成 KPI 指标计算与探索性分析 | KPI 报表 + 时间序列预测模型 |
| 智能层 | 调用大模型 API 构建 NL2SQL 自然语言查询 | AI 智能问答接口 |
| 展示层 | 使用 Superset 与 ECharts 构建仪表板与数据大屏 | 交互式仪表板 + 数据大屏 |
| 工程层 | 全程 Git 版本控制，Docker Compose 一键部署 | 可复现的部署方案 |

---

## 四、技术栈

| 类别 | 技术 / 工具 | 用途 |
|---|---|---|
| 数据仓库 | Apache Hive 4.0.0 | 四层数仓建模与 ETL 计算 |
| 关系型数据库 | MySQL 8.0 | Hive Metastore 元数据存储、ADS 结果回写 |
| 编程语言 | Python（pandas / scikit-learn） | 数据探索与预测建模 |
| AI 协同 | 大模型 API + LangChain | NL2SQL 与智能报告 |
| 可视化 | Apache Superset、ECharts | 仪表板与数据大屏 |
| 交互框架 | Streamlit | 对话式数据问答界面 |
| 部署 | Docker + Docker Compose | 全本地化一键部署 |
| 版本控制 | Git | 版本管理与提交追溯 |

> **环境备注**：本机 `docker compose`（空格）子命令不可用，统一使用 `docker-compose`（横杠）写法。

---

## 五、数据源说明

数据集共 6 张 CSV，合计 **114,809 行**，存放于 `模拟数据/` 目录（数据文件不纳入版本库）。

| 文件名 | ODS 表名 | 行数 | 说明 |
|---|---|---|---|
| ods_user.csv | ods_user | 1,000 | 用户信息表 |
| ods_product.csv | ods_product | 600 | 商品信息表 |
| ods_store.csv | ods_store | 60 | 门店信息表 |
| ods_order.csv | ods_order | 15,600 | 订单主表（含约 600 行重复） |
| ods_order_item.csv | ods_order_item | 37,549 | 订单明细表 |
| ods_user_behavior.csv | ods_user_behavior | 60,000 | 用户行为日志表 |

**源文件格式实测特征**（建表依据）：

- 编码：UTF-8 **带 BOM**（BOM 位于表头行首，通过 `skip.header.line.count=1` 一并跳过）
- 换行：Windows **CRLF**，故建表用 `LINES TERMINATED BY '\r\n'`，否则末字段会残留 `\r`
- 分隔：纯英文逗号，**无引号包裹、无中文逗号、无制表符**，字段数与表头完全一致

---

## 六、目录结构

```
企业项目实战/
├── README.md                  项目说明（本文件）
├── .gitignore                 版本忽略规则
├── .gitattributes             换行符与二进制文件规则
├── data/                      数据文件副本（不纳入版本库）
├── docker/                    Docker 编排相关
│   ├── docker-compose.yml     MySQL + Hive Metastore + HiveServer2
│   ├── .env.example           环境变量模板
│   └── lib/                   JDBC 驱动（MySQL / PostgreSQL）
├── sql/                       SQL 脚本（整体挂载进容器为 /sql）
│   ├── ods/                   ODS 贴源层脚本
│   │   ├── 01_create_database.sql
│   │   ├── 02_create_ods_tables.sql
│   │   └── 03_load_ods_data.sql
│   ├── quality/               数据质量预评估脚本
│   │   └── 01_quality_assessment.sql
│   ├── clean/                 数据清洗脚本
│   │   ├── 01_create_dwd_tables.sql        第1周：建 DWD 表
│   │   ├── 02_handle_missing_values.sql    第1周：缺失值处理
│   │   ├── 03_deduplicate_orders.sql       第1周：订单去重
│   │   ├── 04_cleaning_summary.sql         第1周：清洗汇总
│   │   ├── 05_rebuild_dwd_tables.sql       第2周：重建 DWD + 码表维度
│   │   ├── 06_clean_dim_user.sql           第2周：用户维度清洗
│   │   ├── 07_clean_dim_product.sql        第2周：商品维度清洗
│   │   ├── 08_clean_dim_store.sql          第2周：门店维度清洗
│   │   ├── 09_clean_dwd_order.sql          第2周：订单事实表清洗（按月分区）
│   │   ├── 10_clean_dwd_order_item.sql     第2周：订单明细清洗
│   │   ├── 11_clean_dwd_behavior.sql       第2周：用户行为清洗
│   │   └── 12_quality_compare.sql          第2周：清洗前后质量对比
│   ├── dwd/                   第2周：DWD 建模与分析
│   │   ├── 01_dim_date.sql                 日期维度生成
│   │   ├── 02_eda.sql                      探索性分析
│   │   └── 03_bucket_experiment.sql        分桶表实验（演示级，不进主链路）
│   ├── dws/                   第3周：DWS 汇总层
│   │   ├── 01_create_dws_tables.sql        5 张汇总表建表
│   │   ├── 02_load_dws_trade_day.sql       日 × 渠道
│   │   ├── 03_load_dws_store_month.sql     月 × 门店
│   │   ├── 04_load_dws_product_month.sql   月 × 商品（含金额分摊中间表）
│   │   ├── 05_load_dws_trade_week.sql      周汇总
│   │   └── 06_load_dws_user_agg.sql        用户累计快照
│   ├── ads/                   第3周：ADS 应用层
│   │   ├── 01_create_ads_tables.sql        8 张应用表建表
│   │   ├── 02_load_ads_kpi.sql             核心 KPI
│   │   ├── 03_load_ads_category.sql        品类排名
│   │   ├── 04_load_ads_region.sql          省份排名
│   │   ├── 05_load_ads_user_value.sql      RFM 用户分层
│   │   └── 06_load_ads_funnel_daily.sql    行为漏斗
│   └── fix/                   环境修复脚本
│       └── fix_metastore_charset.sql
├── python/                    第3周：分析、建模与 AI 应用
│   ├── 01_extract_series.py   从 ADS 抽日/月序列
│   ├── 02_predict_gmv.py      特征工程 + 多模型回测 + 7 天预测 + 出图
│   ├── 03_schema_extract.py   抽取 Hive Schema 生成 Prompt 上下文
│   ├── 04_sql_guard.py        NL2SQL 的 SQL 安全校验（只读/表名/字段/LIMIT）
│   ├── 05_nl2sql.py           自然语言 → SQL → 执行 → 结果
│   ├── 06_llm_ping.py         大模型连通性最小验证
│   ├── 07_ai_insight.py       异常检测 + 归因 + 自动报告 + 事实校验
│   ├── common.py              Hive 连接与路径公共模块
│   └── requirements.txt       Python 依赖清单
├── output/                    分析产物（KPI 结果表、预测结果、Schema、自动报告）
├── scripts/
│   ├── prepare_data.py        数据预处理（CRLF→LF、去 BOM、校验）
│   └── build_quality_xlsx.py  质量评估表 xlsx 生成
├── docs/                      项目文档
│   ├── 01_环境搭建笔记.md
│   ├── 02_数据质量预评估表.md
│   ├── 03_数据清洗说明.md
│   ├── 04_Docker环境部署.md
│   ├── 05_Git远程仓库配置.md
│   ├── 06_数据质量清洗报告.md      第2周交付
│   ├── 07_数仓架构设计.md          第2周交付
│   ├── 08_探索性分析简报.md        第2周交付
│   ├── 09_指标口径与ADS设计.md     第3周交付
│   ├── 10_预测建模分析报告.md      第3周交付
│   ├── 11_AI智能洞察与反思.md      第3周交付
│   ├── 12_Git协同实践记录.md       第3周交付
│   └── images/                     截图、架构图与建模图
├── run_all.sh                 一键执行脚本
└── 模拟数据/                  原始数据集（不纳入版本库）
```

---

## 七、阶段计划

| 周期 | 主题 | 核心任务 | 状态 |
|---|---|---|---|
| 第 1 周 | 项目启动 · 环境搭建 · 数据导入与清洗（一） | Docker/Hive/MySQL 环境、Git 规范、ODS 导入、五维预评估、缺失值与重复值处理 | **已完成** |
| 第 2 周 | 清洗进阶 · 四层建模 · 探索性分析 | 枚举标准化、异常值/格式统一、质量对比报告、星型模型、分区表、EDA | **已完成** |
| 第 3 周 | 数据分析 · 预测建模 · AI 协同（NL2SQL） | DWS 汇总层、ADS 指标、KPI 计算、时间序列预测、NL2SQL、AI 洞察、Git 协同实战 | **已完成**（DeepSeek 实测：NL2SQL 7/7 通过，AI 洞察一致率 100%） |
| 第 4 周 | 智能应用 · 可视化 · 部署 | NL2SQL、Superset 仪表板、ECharts 大屏、Docker 一键部署 | 待启动 |

---

## 八、约定与规范

### 8.1 Git 提交规范（Conventional Commits）

| 前缀 | 用途 | 示例 |
|---|---|---|
| `feat:` | 新增功能 / 脚本 | `feat: 新增 ODS 层 6 张表建表脚本` |
| `fix:` | 修复问题 | `fix: 修正订单表行尾符分隔导致的字段错位` |
| `docs:` | 文档变更 | `docs: 补充环境搭建笔记` |
| `refactor:` | 重构 | `refactor: 拆分清洗脚本为缺失值与去重两部分` |
| `chore:` | 杂项 | `chore: 更新 .gitignore 忽略规则` |

### 8.2 数据库命名

- 库：`ydsh_ods` / `ydsh_dwd` / `ydsh_dws` / `ydsh_ads`
- 表：小写下划线，层级前缀，如 `ods_order`、`dwd_order`、`dws_sales_daily`

### 8.3 数据口径声明（重要）

- **营收类指标（GMV、销售额、客单价、营收趋势）统一以 `dwd_order.pay_amount` 为唯一金额来源**，
  且必须带 `is_gmv_included = 1`（已支付 / 已完成计入，待支付 / 已取消 / 退款中不计入）
- `dwd_order_item.item_amount` 是**吊牌价口径**，全年合计约 2.66 亿，是实付金额的 10 倍量级，
  **不得直接用于金额汇总**
- 需要按商品/品类拆分金额时，用「明细金额占比分摊实付金额」的方式：
  `pay_amount × item_amount / 该订单明细金额合计`，保证分摊后各品类合计仍等于 GMV
  （实现见 `sql/dws/04_load_dws_product_month.sql`，四路独立聚合交叉校验见 docs/09 第五节）
- `dwd_order` **没有** `product_id` 字段，商品信息必须经 `dwd_order_item` 关联 `dim_product`

---

## 九、快速开始

### 9.1 一键执行（推荐）

```bash
# 1. 启动基础服务（MySQL + Hive Metastore + HiveServer2）
cd docker
docker-compose up -d
docker-compose ps          # 三个容器均应为 Up

# 2. 回到项目根目录，一键执行全流程
cd ..
bash run_all.sh            # 预处理 → 建库 → 建表 → 导入 → 质量评估 → DWD 清洗
```

`run_all.sh` 会自动完成四件事，无需手工干预：

1. `scripts/prepare_data.py` —— CSV 预处理（CRLF→LF、去 BOM、行数校验）
2. `sql/fix/fix_metastore_charset.sql` —— 修复元数据字符集（保证中文注释正常）
3. ODS 层建库、建表、导入、质量评估
4. DWD 层建表、缺失值填充、订单去重、效果汇总

### 9.2 分阶段执行

```bash
bash run_all.sh ods      # 仅 ODS 层（含预处理与字符集修复）
bash run_all.sh clean    # 仅清洗层（前提：ODS 已就绪）
bash run_all.sh week2    # 第 2 周：重建 DWD + 清洗进阶 + 质量对比 + EDA
bash run_all.sh week3    # 第 3 周 SQL 部分：DWS 汇总层 + ADS 应用层
bash run_all.sh ml       # 第 3 周建模：日序列抽取 + 预测建模（需 Python 依赖）
bash run_all.sh ai       # 第 3 周 AI：Schema 抽取 + AI 洞察 + NL2SQL
bash run_all.sh week3all # 第 3 周全部：DWS + ADS + 建模 + AI
```

Python 阶段用 `PYTHON_BIN` 指定解释器，避免装到系统 Python：

```bash
PYTHON_BIN=/path/to/venv/Scripts/python.exe bash run_all.sh ml
```

`ai` 阶段在未配置 `LLM_API_KEY` 时自动降级：NL2SQL 走规则兜底（输出标注 `OFFLINE`），
AI 洞察用规则模板生成（报告首行标注生成方式），不会伪装成大模型产出。

配置密钥后（DeepSeek 实测）：

```bash
cp .env.example .env    # 填 LLM_API_KEY，.env 已被 .gitignore 排除
PYTHON_BIN=.../Scripts/python.exe bash run_all.sh ai
```

| 脚本 | 实测结果 |
|---|---|
| `06_llm_ping.py` | 连通 1.38s，结构化 JSON 输出可解析 |
| `05_nl2sql.py` | 7/7 通过，结果写 `output/nl2sql_results_llm.csv` |
| `07_ai_insight.py` | 41 处陈述性断言，一致率 100%，另有 3 处决策参数不校验 |

### 9.3 手工执行（调试用）

> **Git Bash 用户注意**：执行任何带容器内路径（`/sql/...`）的 docker 命令前，
> 需要先关闭 MSYS 的自动路径转换，否则 `/sql/ods/x.sql` 会被改写成
> `<Git安装根>/sql/ods/x.sql` 而报 `No such file or directory`。
> 先执行一次即可（当前窗口有效）：
>
> ```bash
> export MSYS_NO_PATHCONV=1
> export MSYS2_ARG_CONV_EXCL='*'
> ```
>
> `run_all.sh` 内部已自动设置，直接跑脚本无需手动处理。

```bash
# 预处理（必须先做，Hive 不支持多字符行分隔符）
python scripts/prepare_data.py

# 修复元数据字符集（保证中文注释）
docker exec -i -e MYSQL_PWD=root ydsh-mysql mysql -uroot < sql/fix/fix_metastore_charset.sql

# 逐脚本执行：sql/ 目录已挂载进容器为 /sql，直接用容器内路径
docker exec hive-server beeline -u jdbc:hive2://localhost:10000 -f /sql/ods/01_create_database.sql
```

> **为什么不用 `docker cp` 传脚本**：Windows + 中文路径 + Git Bash 下不可靠，
> 且失败时若容器残留旧文件会「假装成功、实际执行旧脚本」。
> 现改为把 `sql/` 目录挂载进容器（`../sql:/sql:ro`），脚本直接在容器内执行，没有传输环节。

### 9.4 环境说明

| 项目 | 值 |
|---|---|
| MySQL 宿主机端口 | `13306`（本地 MySQL80 占用 3306） |
| HiveServer2 JDBC | `10000` |
| HiveServer2 Web UI | `http://localhost:10002` |
| Hive Metastore | `9083` |
| 数仓库 | `ydsh_ods` / `ydsh_dwd` / `ydsh_dws` / `ydsh_ads` |
| compose 项目名 | `ydsh`（**必须显式指定**，否则与既有 Dify 项目冲突） |

### 9.5 结果核对基准

| 检查项 | 期望值 |
|---|---|
| ODS 六表行数 | 1000 / 600 / 60 / 15600 / 37549 / 60000 |
| BOM、CR 残留 | 均为 0 |
| DWD 维度表 | dim_user 1000 / dim_product 600 / dim_store 60 / dim_date 366 |
| DWD 事实表 | dwd_order **15000**（12 个月分区）/ dwd_order_item 37549 / dwd_user_behavior 60000 |
| DWD 清洗修复率 | 18 项全部 100%，合计 36,204 条 |
| DWS 汇总表 | trade_day 1463 / trade_week 212 / store_month 720 / product_month 6993 / user_agg 1000 |
| ADS KPI | GMV **24,717,464.96** / 订单 **9,992** / 客单价 **2,473.73** |
| ADS 交叉校验 | 品类 / 省份 / 用户 / 日报四路合计均等于 24,717,464.96 |
| 预测模型 | 线性回归 MAPE 13.65%（常数均值基线 13.19%，模型未战胜基线，见 docs/10） |
| 事实校验 | 自动报告 35 个数字断言，一致率 100% |

### 9.6 相关文档

- `docs/01_环境搭建笔记.md` —— 环境搭建过程、9 个问题的排查与解决
- `docs/02_数据质量预评估表.md` —— 五维度评估与清洗前后对比
- `docs/03_数据清洗说明.md` —— 清洗策略与决策依据
- `docs/04_Docker环境部署.md` —— Docker 编排详解、端口与排错
- `docs/05_Git远程仓库配置.md` —— 远程仓库配置与提交规范

