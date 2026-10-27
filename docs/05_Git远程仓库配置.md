# Git 远程仓库配置指南

> 对应任务：子任务 3「Git 基础与版本管理规范」（20 分）
> 关联文档：`README.md`、`.gitignore`、`.gitattributes`

---

## 一、远程仓库地址从哪来

Git 的「远程地址」不是凭空产生的，必须先在代码托管平台上**建一个空仓库**，平台才会给你这个地址。

流程是：**先建仓 → 拿到地址 → 本地关联 → 推送**

> 本地仓库已经初始化好了（`git init` 已执行，main 分支已有 2 次提交），
> 只差「关联远程」这一步。

---

## 二、在 GitHub 上建空仓库（拿到地址）

### 步骤

1. 浏览器打开 https://github.com 并登录
2. 右上角 **`+`** → **`New repository`**（或直接访问 https://github.com/new）
3. 填写：

| 字段 | 填什么 | 注意 |
|---|---|---|
| **Repository name** | `ydsh-datawarehouse`（或你喜欢的名字） | 只能用英文、数字、`-`、`_` |
| **Description** | `云购生活企业级数据仓库与经营分析可视化系统` | 可选 |
| **Public / Private** | 建议 **Public** | 私有仓库答辩时老师可能看不到；若学校要求私有，记得加老师为协作者 |
| **Add a README file** | ❌ **不要勾** | 勾了会生成初始提交，与本地历史冲突 |
| **Add .gitignore** | ❌ **不要选** | 项目已有自己的 `.gitignore` |
| **Choose a license** | 可选，None 也行 | — |

4. 点 **`Create repository`**

### 地址在哪看

创建成功后，页面会直接显示一段示例命令，里面就有地址：

```
git remote add origin https://github.com/你的用户名/ydsh-datawarehouse.git
                                    └────────────── 这一串就是远程地址 ──────────────┘
```

如果你已经离开了这个页面，随时可以这样找：

> **仓库主页 → 绿色 `<> Code` 按钮 → 弹出框顶部有两个标签页**
> - **HTTPS**：`https://github.com/用户名/仓库名.git`
> - **SSH**：`git@github.com:用户名/仓库名.git`
> 点右侧的小方块图标即可复制。

**这个地址复制给我，我就能帮你完成关联和推送。**

---

## 三、HTTPS 还是 SSH？选哪个

| 方式 | 地址形式 | 优点 | 缺点 |
|---|---|---|---|
| **HTTPS** | `https://github.com/用户名/仓库名.git` | 配置简单，不用生成密钥 | 每次 push 要输密码；GitHub 已不支持账号密码，必须用 **Personal Access Token** |
| **SSH**（推荐） | `git@github.com:用户名/仓库名.git` | 配一次永久免密；更适合长期项目 | 需要生成密钥并添加到 GitHub |

**建议用 SSH**。任务书子任务 3 明确要求「生成 SSH 密钥并添加到 GitHub/GitLab」，**这是交付内容之一**，用 HTTPS 就等于漏了这一项。

### SSH 配置步骤

```bash
# 1. 生成密钥（邮箱换成你的 GitHub 注册邮箱）
ssh-keygen -t ed25519 -C "3102976249@qq.com"
# 连续回车三次：默认路径、空密码、确认空密码

# 2. 查看公钥并复制全部内容
cat ~/.ssh/id_ed25519.pub

# 3. 添加到 GitHub
#    浏览器打开 https://github.com/settings/keys
#    → New SSH key → Title 随便填（如 "my-laptop"）→ Key 粘贴刚才复制的内容 → Add SSH key

# 4. 测试连接
ssh -T git@github.com
# 成功提示：Hi 你的用户名! You've successfully authenticated...
# 首次会问 yes/no，输入 yes 回车
```

### HTTPS + Token 方案（如果不走 SSH）

1. https://github.com/settings/tokens → **Generate new token (classic)**
2. 勾选 `repo` 权限 → 生成 → **复制 token（只显示一次，务必保存）**
3. push 时用户名填 GitHub 用户名，密码位置粘贴 **token**

---

## 四、关联远程并推送

拿到地址后，在项目根目录执行（**地址按实际替换**）：

```bash
cd /f/企业项目实战

# 关联远程仓库（origin 是远程仓库的默认别名）
git remote add origin git@github.com:你的用户名/ydsh-datawarehouse.git

# 确认关联成功（会列出 origin 及地址）
git remote -v

# 首次推送，并建立本地 main 与远程 main 的跟踪关系
git push -u origin main
```

推送成功后，刷新 GitHub 仓库页面就能看到 2 次提交记录和全部文件。

---

## 五、当前仓库状态

| 项目 | 状态 |
|---|---|
| 本地仓库 | ✅ 已初始化 |
| 当前分支 | `main` |
| 提交次数 | 2 次 |
| `.gitignore` | ✅ 已配置（`data/`、`模拟数据/`、`*.csv`、`*.zip`、`.env` 等已忽略） |
| `.gitattributes` | ✅ 已配置（SQL 强制 LF，CSV 按二进制处理） |
| 远程仓库 | ❌ **未配置**（等你的地址） |

### 已有提交历史

```
d2adf34  feat: 新增第1周清洗脚本（缺失值处理 + 订单去重）
4cfdbea  feat: 初始化项目结构，完成第1周 ODS 建表与导入脚本
```

---

## 六、后续提交规范

任务书要求遵循 Conventional Commits，本项目采用：

| 前缀 | 用途 | 示例 |
|---|---|---|
| `feat:` | 新增功能/脚本 | `feat: 新增 DWS 层日汇总宽表` |
| `fix:` | 修复问题 | `fix: 修正订单去重排序未处理斜杠日期格式` |
| `docs:` | 文档变更 | `docs: 补充 Hive 元数据初始化说明` |
| `refactor:` | 重构（不改功能） | `refactor: 拆分质量评估脚本为六段` |
| `chore:` | 杂项（配置、依赖） | `chore: 添加 mysql-connector 驱动` |

### 日常提交流程

```bash
git status                  # 看改了哪些文件
git diff                    # 看具体改动
git add -A                  # 或 git add 具体文件
git commit -m "feat: 具体做了什么"
git push
```

### 交付前检查清单

答辩要求「远程仓库已推送本周全部成果，提交历史清晰可追溯」，因此：

- [ ] 每次完成一个子任务就提交一次，**不要攒到最后一次性提交**
- [ ] 提交信息写清楚「做了什么」，不要写 `update`、`修改`、`1`
- [ ] `git status` 应为 clean（没有未提交的改动）
- [ ] `git log --oneline` 能看出完整开发脉络
- [ ] 确认 CSV 等大文件**没有**被提交上去（`git log --stat` 检查）

---

## 七、常见问题

### 推送报 `failed to connect to github.com port 443`

国内网络访问 GitHub 常不稳定。

```bash
# 测试连通性
ssh -T git@github.com
ping github.com

# 若 SSH 不通，改用 HTTPS（走 443，通常更容易通）
git remote set-url origin https://github.com/用户名/仓库名.git
```

### 推送报 `rejected - fetch first` 或 `non-fast-forward`

远程仓库不是空的（建仓时勾了 README 或 .gitignore）。

```bash
# 方案 A：拉取并合并（保留双方提交）
git pull --rebase origin main
git push -u origin main

# 方案 B：如果远程那个初始提交没用，强制覆盖（谨慎）
git push -u origin main --force
```

### 推送报 `remote: Permission to xxx denied`

SSH 密钥没加到 GitHub，或加错了账号。重新执行第三节的 `cat ~/.ssh/id_ed25519.pub` → 添加到 https://github.com/settings/keys。

### 发现 CSV 被提交上去了

`.gitignore` 是在提交之后才生效的，已经入库的文件需要先从索引移除：

```bash
git rm --cached -r data 模拟数据
git rm --cached "*.csv"
git commit -m "chore: 移除误提交的数据文件"
```

---

## 八、需要你提供的信息

只需一样：**远程仓库地址**（HTTPS 或 SSH 均可）。

拿到后我会执行：

```bash
git remote add origin <你的地址>
git remote -v          # 验证
git push -u origin main
```

如果你想自己推，按第四节的三条命令执行即可；执行完把 `git remote -v` 和 `git log --oneline` 的输出发我，我帮你确认是否规范。
