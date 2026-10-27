# Docker 环境部署说明（Hive + MySQL）

> 对应任务：子任务 2「开发环境搭建」
> 编排文件：`docker/docker-compose.yml`
> 本文档回答三个问题：**用本地还是 Docker？怎么配置？配好之后怎么验证？**

---

## 一、结论：必须用 Docker Compose，不能用本地 Hive

这个不是选择题，三位一体的文档里三处明确要求：

| 出处 | 原文要求 |
|---|---|
| 《项目总说明》二、项目目标 · 工程层 | 「全程使用 Git 版本控制，**使用 Docker Compose 完成多服务一键部署**」 |
| 《项目总说明》三、技术栈与环境 · 部署 | 「Docker + Docker Compose —— **全本地化一键部署**」 |
| 《第1周部署操作手册》步骤 2 | 「**编写 docker-compose.yml 启动 Hive + MySQL**」 |
| 《第1周任务书》五、交付物清单 | 「Docker/Hive/MySQL **环境可运行**」 |

所以：

- ✅ **要交**：`docker-compose.yml` 编排文件 + 三个容器能起来
- ❌ **不能只交**：本地装的 Hive（即使能跑通，也缺「一键部署」这个交付物，环境搭建那 20 分要丢分）
- ⚠️ 本机已有本地 MySQL 在跑（占用 3306），**不影响 Docker 方案**，只需换端口（本方案已换成 13306）

如果你本地 Hive 能用，那它只能作为**调试辅助**，最终交付仍以 Docker 编排为准。

---

## 二、环境构成

```
                    ┌──────────────────────────────┐
   beeline :10000   │   hive-server (HiveServer2)  │
   Web UI  :10002   │   apache/hive:4.0.0          │
                    └───────────────┬──────────────┘
                                    │ thrift :9083
                    ┌───────────────▼──────────────┐
                    │   hive-metastore             │  ← 元数据服务
                    │   apache/hive:4.0.0          │
                    └───────────────┬──────────────┘
                                    │ JDBC :3306（容器内）
                    ┌───────────────▼──────────────┐
   宿主机 :13306    │   mysql (元数据库)            │
                    │   mysql:8.0                  │
                    └──────────────────────────────┘
```

| 服务 | 镜像 | 容器名 | 宿主机端口 | 作用 |
|---|---|---|---|---|
| mysql | mysql:8.0 | `ydsh-mysql` | **13306** → 3306 | 存 Hive 元数据 |
| hive-metastore | apache/hive:4.0.0 | `hive-metastore` | 9083 | 元数据服务（Thrift） |
| hive-server | apache/hive:4.0.0 | `hive-server` | 10000 / 10002 | SQL 执行入口 |

> **端口为什么改 13306**：本机已有本地 MySQL（`mysqld.exe`）占用 3306，直接映射会冲突。
> 容器内部仍用标准 3306，只是宿主机侧映射到 13306，**Hive 连的是容器网络内的 `mysql:3306`，不受影响**。

---

## 三、配置详解（五个关键点）

### 3.1 SERVICE_NAME 决定容器角色

Hive 4.0.0 官方镜像是一个镜像跑两种角色，靠 `SERVICE_NAME` 区分：

```yaml
# 元数据服务
SERVICE_NAME: metastore
# SQL 服务
SERVICE_NAME: hiveserver2
```

所以 `metastore` 和 `hiveserver2` **必须起成两个容器**，不能合并。

### 3.2 配置注入方式：SERVICE_OPTS，不是 HIVE_SITE_CONF_*

Hive 4.0 已经不读旧版的 `HIVE_SITE_CONF_xxx` 环境变量了。现在的写法是用 `SERVICE_OPTS` 以 `-D` 形式注入：

```yaml
SERVICE_OPTS: >-
  -Djavax.jdo.option.ConnectionDriverName=com.mysql.cj.jdbc.Driver
  -Djavax.jdo.option.ConnectionURL=jdbc:mysql://mysql:3306/metastore?...
  -Djavax.jdo.option.ConnectionUserName=hive
  -Djavax.jdo.option.ConnectionPassword=hive
```

`>-` 是 YAML 折叠语法，把多行拼成一行空格分隔的字符串 —— 正好符合 `-D` 参数序列的格式。

### 3.3 MySQL 8 的连接串必须加两个参数

```
?useSSL=false&allowPublicKeyRetrieval=true
```

- **不加 `allowPublicKeyRetrieval=true`** → 报 `Public Key Retrieval is not allowed`（MySQL 8 默认用 caching_sha2_password 认证）
- **不加 `useSSL=false`** → 报 SSL 相关连接错误

这是 MySQL 8 与 Hive 8.0 之前版本配合时最常见的坑。

### 3.4 必须挂载 MySQL JDBC 驱动

**`apache/hive` 镜像里不含 MySQL 驱动**，不挂载会报：

```
java.lang.ClassNotFoundException: com.mysql.cj.jdbc.Driver
```

所以要把 `mysql-connector-j-8.4.0.jar` 挂到 `/opt/hive/lib/` 下（metastore 和 hiveserver2 两个容器都要挂）。

驱动获取方式（任选其一）：

```bash
# 方式 A：从 Maven 中央仓库下载（本项目已用此方式，实测可用）
cd docker
mkdir -p lib
curl -L -o lib/mysql-connector-j-8.4.0.jar \
  https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.4.0/mysql-connector-j-8.4.0.jar

# 方式 B：如果项目仓库里已有该文件，直接复用
ls -lh docker/lib/mysql-connector-j-8.4.0.jar
```

> 项目已将这个 2.2 MB 的 jar 纳入版本库，克隆后无需再下载。

### 3.5 warehouse 卷必须共享

`hive-metastore` 与 `hive-server` 挂载**同一个 named volume** `hive-warehouse`：

```yaml
volumes:
  - hive-warehouse:/opt/hive/data/warehouse
```

原因是：Metastore 负责记录「表在哪里」，HiveServer2 负责真正读写数据文件。如果两者看不到同一个目录，会出现「建表成功但查不到数据」或 `File not found` 的诡异问题。

### 3.6 元数据初始化：IS_RESUME 开关

Metastore 首次启动时需要建元数据表（`schematool -initSchema`）。

- **首次启动**：`IS_RESUME=false`（默认），自动初始化
- **如果 MySQL 数据卷已存在**：必须设 `IS_RESUME=true` 跳过初始化，否则 `schematool` 会因 `Schema already exists` 失败退出，容器起不来

通过 `.env` 文件控制：

```bash
# docker/.env
HIVE_IS_RESUME=true     # 第二次及以后启动时加上这行
```

---

## 四、启动步骤

### 4.1 前置检查

```bash
# 1. Docker 引擎可用
docker info --format '{{.ServerVersion}}'

# 2. compose 命令可用（本机是 docker-compose，带横杠）
docker-compose version

# 3. 端口未被占用（3306 已被本地 MySQL 占用，故本方案用 13306）
netstat -ano | findstr ":13306 :9083 :10000 :10002"
```

### 4.2 启动

```bash
cd docker

# 首次启动（会自动初始化元数据表）
docker-compose up -d

# 查看状态，等待三个容器都是 Up
docker-compose ps
```

**首次启动耗时**：镜像下载约 3 GB（mysql 600 MB + hive 2.2 GB ×1 份），
加上 Metastore 初始化，通常 3～8 分钟。后续启动约 40 秒。

### 4.3 验证

```bash
# ① 三个容器都 Up
docker-compose ps

# ② Metastore 日志无报错
docker-compose logs --tail 30 hive-metastore | grep -i -E "error|exception" || echo "无报错"

# ③ HiveServer2 连得上
docker exec -it hive-server beeline -u jdbc:hive2://localhost:10000 -e "show databases;"

# ④ 数据目录挂载成功（应看到 6 个 csv）
docker exec hive-server ls -l /data

# ⑤ MySQL 里已建出元数据表
docker exec ydsh-mysql mysql -uhive -phive -e "use metastore; show tables;" | head
```

**全部通过的标准**：

| 检查项 | 期望结果 |
|---|---|
| 容器状态 | `ydsh-mysql` / `hive-metastore` / `hive-server` 三者均 Up |
| beeline 连通 | 输出 `default` 等数据库列表 |
| `/data` 挂载 | 列出 6 个 CSV 文件 |
| 元数据表 | metastore 库中有 `TBLS`、`DBS` 等表 |

---

## 五、已知问题与解决方案

### 问题 1：拉取镜像报 `unexpected media type text/html`

- **现象**：`docker pull mysql:8.0` 报
  `failed to unpack image on snapshotter overlayfs: unexpected media type text/html`
- **根因**：`daemon.json` 中部分镜像源已失效，返回 HTML 错误页，Docker 误当作镜像层解析，
  并把这个坏内容缓存成本地镜像（表现为 0 B、多个 tag 指向同一 ID）
- **解决**：

```bash
# ① 清掉损坏的 0B 镜像（先看有几个）
docker images --format "{{.Repository}}:{{.Tag}} | {{.ID}} | {{.Size}}" | grep 0B
docker rmi alpine:3.19 mysql:8.0

# ② 重新拉取
docker pull mysql:8.0
```

如果仍然失败，直接用**指定的可用源**拉取，这样不改动 `daemon.json`：

```bash
# 官方镜像（Docker Hub library 下的）→ 路径要带 library/
docker pull docker.1ms.run/library/mysql:8.0
docker tag  docker.1ms.run/library/mysql:8.0  mysql:8.0

# 非官方镜像（有命名空间的）→ 路径不带 library/
docker pull docker.1ms.run/apache/hive:4.0.0
docker tag  docker.1ms.run/apache/hive:4.0.0  apache/hive:4.0.0
```

> **⚠️ 路径规则（很容易错）**：
> `library/` 前缀**只用于 Docker Hub 官方镜像**（mysql、alpine、nginx、redis、postgres 等，
> 它们完整名是 `library/mysql`）。带命名空间的镜像如 `apache/hive` **不能加** `library/`，
> 否则报 `not found`。
>
> | 镜像 | 正确路径 |
> |---|---|
> | `mysql:8.0` | `docker.1ms.run/library/mysql:8.0` |
> | `alpine:3.19` | `docker.1ms.run/library/alpine:3.19` |
> | `apache/hive:4.0.0` | `docker.1ms.run/apache/hive:4.0.0` |

### 镜像源实测记录（2026-10-27）

`daemon.json` 中原有 21 条镜像源，逐条探测 `/v2/` 端点结果：

| 镜像源 | HTTP 状态 | 判定 |
|---|---|---|
| `docker.1ms.run` | 401 | ✅ **可用**（token 换 manifest 实测 200） |
| `docker.xuanyuan.me` | 401 | ✅ **可用**（同上） |
| `docker.1panelproxy.com` | 302 | ⚠️ 部分可用（manifest 阶段返回 403） |
| `docker.m.daocloud.io` | 401 / 间歇 000 | ⚠️ 不稳定（TLS 超时频发） |
| `https://your_preferred_mirror` | 000 | ❌ 占位符，非真实地址 |
| 其余 16 条（163、baidubce、aliyun、nju、ustc 等） | 000 | ❌ 全部超时失效 |

**结论**：多数公共免费镜像源已失效，且链路不稳定，同一个源在不同时刻可能通或不通。
因此推荐两种做法：

1. **临时绕过**（不改配置）：`docker pull <可用源>/library/<镜像>:<标签>` 然后 `docker tag` 回标准名
2. **长期方案**：在 `daemon.json` 的 `registry-mirrors` 中只保留实测可用的 1～2 条，
   避免 Docker 在死源上逐个超时（**改动前先备份原文件**）

> **典型症状**：`docker pull` 长时间无任何输出（不是报错，是卡住），
> 说明正在按列表顺序逐个尝试已失效的源。此时应直接指定可用源。

### 问题 2：`/data` 目录为空

- **现象**：`docker exec hive-server ls /data` 没有任何文件
- **根因**：项目路径含中文（`F:\企业项目实战`），个别 Docker 版本对中文路径 bind mount 支持不佳
- **解决**：改用 `docker cp` 直接拷进容器

```bash
docker exec hive-server mkdir -p /data
docker cp ../data/. hive-server:/data/
docker exec hive-server ls -l /data
```

> 注意 `docker cp` 的副本在容器重建后会丢失，重建后需重新执行。

### 问题 3：Metastore 容器反复重启

- **现象**：`hive-metastore` 状态在 `Restarting` 之间循环
- **排查**：`docker-compose logs --tail 50 hive-metastore`
- **两种常见原因**：

| 日志特征 | 原因 | 解决 |
|---|---|---|
| `ClassNotFoundException: com.mysql.cj.jdbc.Driver` | 驱动 jar 没挂上 | 检查 `docker/lib/` 下是否有 jar，路径是否正确 |
| `Schema already exists` / `schematool` 失败 | 元数据库已有表，又执行了初始化 | 在 `docker/.env` 中设 `HIVE_IS_RESUME=true` |
| `Public Key Retrieval is not allowed` | 连接串缺参数 | URL 加 `allowPublicKeyRetrieval=true&useSSL=false` |

### 问题 4：HiveServer2 连不上 Metastore

- **现象**：beeline 报 `Could not connect to thrift://hive-metastore:9083`
- **排查**：
  ```bash
  docker-compose ps                      # metastore 是否 Up
  docker exec hive-server ping -c 2 hive-metastore   # 网络是否通
  ```
- **根因**：`hive-server` 的 `depends_on` 只保证「metastore 容器已启动」，
  不保证「Metastore 服务已就绪」。Metastore 初始化需要时间。
- **解决**：等 30～60 秒后重试；或重启 hive-server：`docker-compose restart hive-server`

### 问题 5：`docker compose` 子命令不存在

- **现象**：`docker compose version` 报 `unknown command`
- **解决**：统一用 `docker-compose`（带横杠，v5.1.3）。本项目所有脚本均按此写法。

---

## 六、常用运维命令

```bash
cd docker

docker-compose ps                       # 查看状态
docker-compose logs -f hive-server      # 跟踪日志
docker-compose restart hive-server      # 重启单个服务
docker-compose stop                     # 停止（保留数据）
docker-compose down                     # 删除容器（保留 named volume，元数据还在）

# 彻底重置（连元数据一起清空，慎用）
docker-compose down -v

# 进入 beeline 交互
docker exec -it hive-server beeline -u jdbc:hive2://localhost:10000
```

---

## 七、资源占用参考

| 项目 | 数值 |
|---|---|
| 镜像总大小 | 约 2.8 GB（mysql 600 MB + hive 2.2 GB，两个 Hive 容器共用同一镜像） |
| 运行时内存 | mysql ≈ 400 MB，metastore ≈ 700 MB，hiveserver2 ≈ 1.2 GB，合计约 2.3 GB |
| 宿主机内存 | 建议 ≥ 8 GB 可用（本机 16 GB，Docker VM 分配 8 GB，余量充足） |
| 磁盘（含元数据与 warehouse） | 首周约 1 GB 增量 |
