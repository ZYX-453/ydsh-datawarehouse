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
├── sql/
│   ├── ods/                   ODS 贴源层脚本
│   │   ├── 01_create_database.sql
│   │   ├── 02_create_ods_tables.sql
│   │   └── 03_load_ods_data.sql
│   ├── quality/               数据质量预评估脚本
│   │   └── 01_quality_assessment.sql
│   └── clean/                 数据清洗脚本（缺失值 / 去重）
├── docs/                      项目文档
│   ├── 01_环境搭建笔记.md
│   └── 02_数据质量预评估表.md
└── 模拟数据/                  原始数据集（不纳入版本库）
```

---

## 七、阶段计划

| 周期 | 主题 | 核心任务 | 状态 |
|---|---|---|---|
| 第 1 周 | 项目启动 · 环境搭建 · 数据导入与清洗（一） | Docker/Hive/MySQL 环境、Git 规范、ODS 导入、五维预评估、缺失值与重复值处理 | 进行中 |
| 第 2 周 | 维度建模 · DWD/DWS 建设 | 维度建模、ETL 全流程、异常值与格式统一清洗 | 待启动 |
| 第 3 周 | ADS 指标 · 分析与预测 | KPI 指标计算、探索性分析、时间序列预测 | 待启动 |
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

- **营收类指标（GMV、销售额、客单价、营收趋势）统一以 `ods_order.pay_amount` 为唯一口径**
- `ods_order_item` 仅用于结构分析：品类占比、销量、件数、连带率，不参与金额汇总

---

## 九、快速开始

```bash
# 1. 启动基础服务（MySQL + Hive Metastore + HiveServer2）
cd docker
docker-compose up -d
docker-compose ps

# 2. 进入 beeline
docker exec -it hive-server beeline -u jdbc:hive2://localhost:10000

# 3. 一键执行全部脚本（ODS 建库 → 建表 → 导入 → 质量评估 → DWD 清洗）
cd ..
bash run_all.sh

# 4. 或分阶段执行
bash run_all.sh ods      # 仅 ODS 层
bash run_all.sh clean    # 仅清洗层
```

> **端口说明**：本机已有本地 MySQL 占用 3306，故 compose 中 MySQL 映射为宿主机 `13306`；
> Hive 通过容器网络 `mysql:3306` 连接，不受影响。HiveServer2 为 `10000`，Web UI 为 `10002`。

详细步骤与踩坑记录见：

- `docs/01_环境搭建笔记.md` —— 环境搭建过程与问题记录
- `docs/04_Docker环境部署.md` —— Docker 编排详解、端口与排错
- `docs/05_Git远程仓库配置.md` —— 远程仓库配置与提交规范
