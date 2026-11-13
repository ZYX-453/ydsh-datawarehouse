# Git 团队协同实践记录

> 项目：云购生活新零售企业 · 企业级数据仓库
> 周次：第 3 周　|　交付物 ⑥
> 仓库：`git@github.com:ZYX-453/ydsh-datawarehouse.git`
> 记录范围：第 3 周全部开发活动（Issue 追踪 → 分支开发 → Code Review → 合并冲突解决）

---

## 一、先说清楚一件事：单人项目怎么"协同"

任务书要求实践 Fork 工作流、PR、Code Review。本项目是**一人开发**，没有第二个可以 Fork 的账号。
硬造一个假 PR 意义不大，所以采取的做法是：

1. **真做**能单人完成的部分：Issue 台账、特性分支、逐项 Code Review、真实合并冲突、合并提交双亲可查；
2. **写清**需要双人才能做的部分：Fork/PR/Review 评论的完整操作步骤与模板，附在第六节，队友加入后可直接照做，不用重写；
3. 所有留痕都指向仓库里真实存在的 commit hash，可 `git show` 逐条验证。

**评判标准很简单：本文档里出现的每个 hash，`git log` 里都能查到。**

---

## 二、Issue 台账

单人项目没有 GitHub Issue 页面，但"先记问题再改代码"的纪律不能省。以下是本周真实处理过的问题，
每条都有对应的修复提交。第九、十条是配置密钥做真实 NL2SQL 实测时才暴露出来的。

| ID | 类型 | 标题 | 优先级 | 状态 | 对应提交 |
|---|---|---|---|---|---|
| ISSUE-01 | bug | 品类销售额口径错误：`dwd_order` 没有 `product_id` | P0 | 已关闭 | `4faae00` |
| ISSUE-02 | bug | SQL 守卫把字面量里的关键字误判为写操作 | P1 | 已关闭 | `98f1972` |
| ISSUE-03 | bug | SQL 守卫漏校验单表裸字段，`product_id` 直接放行 | P0 | 已关闭 | `07c050e` |
| ISSUE-04 | improvement | LIMIT 过大（如 100000）时静默放行 | P2 | 已关闭 | `ccf532c` |
| ISSUE-05 | bug | 预测模型缺少基线对照，"最优模型"实际不如均值 | P1 | 已关闭 | `98f1972` |
| ISSUE-06 | chore | `run_all.sh` 缺 Python 阶段，第 3 周要手工跑 4 个脚本 | P2 | 已关闭 | `9f5faef` |
| ISSUE-07 | incident | `.git` 对象库部分损坏，提交与分支引用丢失 | P0 | 已关闭 | 见第七节 |
| ISSUE-08 | blocked | 未配置 `LLM_API_KEY`，NL2SQL 只验证了离线兜底模式 | P0 | 已关闭 | 见 3.3 |
| ISSUE-09 | bug | schema 注释与真实枚举值不一致，模型照抄后静默返回 0 行仍判"通过" | P0 | 已关闭 | 见 3.3 |
| ISSUE-10 | bug | 事实校验器把「万元」和「建议阈值」误判为无据，产生假阳性 | P1 | 已关闭 | 见 3.3 |

### 逐条说明

**ISSUE-01（P0）** 手册示例 `join dim_product p on o.product_id = p.product_id` 根本跑不通——
`dwd_order` 是订单粒度，商品挂在 `dwd_order_item` 上。正确做法是按明细金额占比把
`pay_amount` 分摊到商品。直接把订单金额挂到每个商品上，品类销售额会放大 10 倍量级。
修复提交里写了分摊中间表 `stg_order_item_base` / `stg_order_amount` 的设计。

**ISSUE-02（P1）** `select * from ads_kpi_overview where stat_scope = 'a drop test'` 被拒绝执行，
只因为字面量里有个 `drop`。关键字扫描是纯文本匹配，必须先摘掉字符串字面量。

**ISSUE-03（P0）** 这是本周最要紧的一个。守卫只校验 `别名.字段` 形式，
`select product_id from dwd_order` 因为没写别名被整个放过——而这恰恰是最容易出错的一类。
属于**校验规则本身有盲区**，比单个 SQL 写错更危险。

**ISSUE-05（P1）** 初版只报了"线性回归 MAPE 13.65%"就收工，看起来还行。
补上常数均值基线后发现基线是 13.19%，模型根本没打败"直接猜均值"。
这不是调参能解决的，是数据无结构导致的，已在预测报告里如实披露。

**ISSUE-08（P0，已关闭）** 没有 API Key 时，`05_nl2sql.py` 只能跑离线兜底（规则模板），
`07_ai_insight.py` 只能出规则报告。配 key 后实测：连通性 1.38s，NL2SQL 7 题全通，
洞察报告一致率 100%。修复方式就是补 `.env`（已确认被 `.gitignore` 第 11 行排除，不进库）。

**ISSUE-09（P0）** 配 key 后第一次跑 NL2SQL，「2024 年全年 GMV」这题**返回 0 行却计入通过**。
两个独立缺陷叠在一起：
一是 `03_schema_extract.py` 只抽字段注释，而 `ads_kpi_overview.stat_scope` 的注释写的是
「统计口径范围，如 2024 全年」，真实值却是 `2024 全年（成交口径）`，模型忠实照抄注释 →
WHERE 匹配不上 → 0 行；二是 `05_nl2sql.py` 只判执行异常，**不判结果是否为空**，
于是"SQL 合法、语义错了"的静默错误被当成成功汇报。
修法：抽取器对低基数列（distinct ≤ 12）采样真实取值写进 Prompt；主链路把"0 行"也当作失败并回灌自修正。

**ISSUE-10（P1）** 洞察报告第一次一致率只有 96.2%，报了两个无据数字 `367.45`、`293.25`。
查下去发现模型没编造——它们分别是 3,674,468.80 元和 2,932,538.21 元的**万元写法**，
而校验器只按"元"比对。第二次又报了 `30%`，那是行动建议里的告警阈值，属于决策参数而非数据断言。
**校验器自身会误伤**，这比模型幻觉更隐蔽：如果不查证就当成幻觉写进报告，会把正确的表述污名化。
修法：候选值增加万元/亿元折算；按章节区分陈述性内容与行动建议，建议里的数字单独标为"决策参数"。

---

## 三、分支与提交

### 3.1 分支模型

单人项目用简化的 GitHub Flow：`main` 保持可运行，功能/修复各开短分支，合并后删除。

| 分支 | 用途 | 起始点 | 结束 |
|---|---|---|---|
| `main` | 交付主线，任何时点可 `run_all.sh` 复现 | — | 持续 |
| `guard-bare-column` | ISSUE-03 的修复 | `c218937` | 已合并 `6f582ec`，保留未删 |

> 命名说明：常规会用 `fix/xxx` 带斜杠形式。本项目所在环境对 `.git/refs/heads/` 下**新建子目录**的引用文件
> 存在丢失现象（详见第七节），为避免引用再次消失，改用扁平名 `guard-bare-column`。
> 这是环境限制下的妥协，不是规范偏好。

### 3.2 提交规范

采用 Conventional Commits：`type(scope): subject`，正文写"为什么"而非"做了什么"。

| type | 用途 | 本周实例 |
|---|---|---|
| feat | 新增能力 | `feat(dws)` `feat(ads)` `feat(ml)` |
| fix | 修缺陷 | `fix(nl2sql)` |
| docs | 文档 | `docs:` 指标口径与 ADS 设计 |
| chore | 工程配置 | `chore:` run_all.sh 阶段 |
| merge | 合并提交 | `merge:` 冲突解决 |

### 3.3 第 3 周提交序列

```
7056ee8 fix(ai): 校验器识别万元与建议阈值，补 σ 倍数与人工复核
72b0fa1 fix(nl2sql): 采样真实枚举值，空结果不再判为通过
6f582ec merge: 合并 guard-bare-column 到 main，解决闸 2c 与闸 3 的冲突
├─ 07c050e fix(nl2sql): 补单表裸字段校验，拦住 dwd_order.product_id 这类错
└─ ccf532c feat(nl2sql): LIMIT 过大时告警，不再静默放行
c218937 docs: 第2周周志按提交标准重写
9f5faef chore: run_all.sh 新增 ml / ai / week3all 阶段，补 requirements.txt
3c16f76 docs: 指标口径与 ADS 设计、预测建模分析报告
67eae15 chore(ai): 新增 .env.example 密钥模板
98f1972 feat(ml): 时间序列抽取、预测建模与 NL2SQL/AI 洞察脚本
ed045fb feat(ads): ADS 应用层八张表与 KPI 计算
4faae00 feat(dws): DWS 汇总层五张表（日/周/月 × 渠道/门店/商品/用户）
4ec6c8c chore: 归档第3周任务书与部署手册，output 产物解禁入库
```

### 3.4 配置密钥后的实测轮次

最后两个提交不是在"实现功能"，而是在**实测中修掉前一轮自己没发现的问题**。
这一段值得单独记，因为它说明「代码写完了」和「功能验证过」是两回事。

| 轮次 | 做了什么 | 暴露的问题 | 结果 |
|---|---|---|---|
| 1 | 填 `.env`，跑 `06_llm_ping.py` | — | 连通 1.38s，结构化 JSON 可解析 |
| 2 | 首跑 `05_nl2sql.py` | 第 1 题**返回 0 行却计入通过** | 7/7"通过"，但其中 1 题是假的 |
| 3 | 查 `stat_scope` 真实值 → 修抽取器与主链路 | ISSUE-09 | 7/7 真通过，第 1 题 24,717,464.96 元 |
| 4 | 首跑 `07_ai_insight.py` | 一致率 96.2%，报 2 个"无据"数字 | 查证是万元写法，校验器误伤 |
| 5 | 修单位归一化 → 重跑 | 又报 `30%`，是建议里的阈值 | ISSUE-10 |
| 6 | 加章节切分 + σ 倍数 → 重跑 | — | 41 处断言，一致率 100% |

**第 2 轮是全周最值得警惕的一次**：如果只看到"7/7 通过"就收工，
交付的会是一个有 1/7 概率静默返回空表的 NL2SQL，而且错误完全无声。


---

## 四、Code Review 记录

### 4.1 评审清单

单人项目也得有人挑刺，评审按固定清单逐项过，避免"自己看自己写的代码觉得都对"：

| # | 检查项 | 关注点 |
|---|---|---|
| 1 | 口径 | 指标是否都带 `is_gmv_included = 1`；金额是否误用 `round(double,n)` |
| 2 | 边界 | 空表、单行、NULL 值、除零（客单价分母为 0） |
| 3 | 安全 | NL2SQL 是否可能跑出写操作；是否强制 LIMIT |
| 4 | 防泄漏 | 时间序列特征是否用了未来信息；切分是否按时间 |
| 5 | 可复现 | 换台机器能否一键跑通；依赖是否声明 |
| 6 | 诚实性 | 结果不好看的地方有没有被藏起来 |

### 4.2 评审发现（3 项，均已修复）

| 发现 | 严重度 | 处理 |
|---|---|---|
| 守卫对单表裸字段完全无校验（ISSUE-03） | 高 | `07c050e` 新增闸 2c |
| 守卫把字面量内容当 SQL 关键字（ISSUE-02） | 中 | `98f1972` 新增 `_strip_literals()` |
| LIMIT 写多大都不吭声（ISSUE-04） | 低 | `ccf532c` 增加上限告警 |

### 4.3 一个"自己 review 自己"也差点漏掉的细节

写闸 2c 的第一版用的是负向断言：

```python
re.findall(r"(?<![.\w])([a-z_]\w*)(?!\s*[.(])", s)
```

跑内置用例立刻炸了：`sum(` 被匹配成 `su`。原因是正则回溯——`sum` 后面跟着 `(`，
前瞻断言失败后引擎退回匹配更短的 `su`，这时下一个字符是 `m`，断言反而通过了。

改成 `finditer` + 手工检查后一个字符才正确：

```python
for m in re.finditer(r"(?<![.\w])([a-z_]\w*)", s):
    nxt = s[m.end():m.end() + 2].lstrip()
    if nxt[:1] in ("(", "."):      # 函数调用 / 库名表名前缀
        continue
    out.append(m.group(1))
```

**这条写进评审记录的原因**：如果只写 `query = "select sum(gmv) ..."` 这一条测试，可能就漏过去了。
是"内置用例集"把它挡住的——所以断言用例本身就是评审资产。

### 4.4 评审结论

8 项内置断言全过、NL2SQL 离线 7 条真实 SQL 无回归，同意合并。

---

## 五、真实合并冲突

### 5.1 冲突是怎么产生的

两条工作线都改在 `04_sql_guard.py` 的同一位置——"闸 2b 之后、闸 3 之前"：

| 分支 | 改动内容 | 提交 |
|---|---|---|
| `main` | 在闸 3 增加"LIMIT 过大告警" | `ccf532c` |
| `guard-bare-column` | 在闸 2b 与闸 3 之间插入闸 2c（裸字段校验） | `07c050e` |

两者插入点相邻，Git 无法判断先后顺序，标记为冲突：

```
Auto-merging python/04_sql_guard.py
CONFLICT (content): Merge conflict in python/04_sql_guard.py
Automatic merge failed; fix conflicts and then commit the result.
```

冲突区（`git status` 显示 `UU python/04_sql_guard.py`）：

```text
<<<<<<< HEAD
    # 闸 3：补 LIMIT，并对过大的 LIMIT 告警
    #   补 LIMIT 是为了防止「查全表」；反过来，模型偶尔会写 LIMIT 100000 这种，
    #   在 Hive 上等于把结果全拉回客户端，同样要提示。
=======
    # 闸 2c：单表查询的裸字段校验
    ...
    uniq_tables = sorted(set(resolved))
    if len(uniq_tables) == 1:
        ...
=======
    # 闸 3：补 LIMIT
>>>>>>> guard-bare-column
```

### 5.2 解决决策

**不是简单"选一边"，而是判断两段逻辑的先后依赖**：

- 闸 2c 校验的是"字段是否存在"→ 字段不存在，SQL **必然执行失败**，属于硬错误；
- 闸 3 的 LIMIT 告警是性能提示 → 即使 LIMIT 很大，语句仍能跑通。

所以顺序定为 **闸 2c → 闸 3**：先拦必错的，再提示慢的。

### 5.3 验证

解决后必须证明"两边都没被弄丢"，而不是只看有没有冲突标记：

| 验证项 | 结果 |
|---|---|
| 冲突标记残留 | 0 处 |
| 内置断言 | 8 项全过 |
| ISSUE-03 场景 `select product_id from dwd_order` | 正确拦截 |
| ISSUE-04 场景 `limit 50000` | 正确告警 |
| NL2SQL 离线 7 条真实 SQL | 0 条被误拦 |

### 5.4 合并提交

`6f582ec` 是**双亲合并提交**，可查证：

```bash
$ git cat-file -p 6f582ec | head -3
tree cc93288...
parent ccf532c...      # main 线
parent 07c050e...      # 特性分支
```

```
$ git log --graph --oneline -4
*   6f582ec merge: 合并 guard-bare-column 到 main，解决闸 2c 与闸 3 的冲突
|\
| * 07c050e fix(nl2sql): 补单表裸字段校验，拦住 dwd_order.product_id 这类错
* | ccf532c feat(nl2sql): LIMIT 过大时告警，不再静默放行
|/
* c218937 docs: 第2周周志按提交标准重写
```

---

## 六、Fork + PR + Review 流程（双人场景可直接照做）

以下是队友加入后的标准流程，命令按本项目实际远程地址填写：

### 6.1 Fork 与克隆

```bash
# 1. 在 GitHub 网页 Fork 主仓库到自己账号（得到 <你的账号>/ydsh-datawarehouse）
# 2. 克隆自己的 fork，并把主仓库加为 upstream
git clone git@github.com:<你的账号>/ydsh-datawarehouse.git
cd ydsh-datawarehouse
git remote add upstream git@github.com:ZYX-453/ydsh-datawarehouse.git

# 3. 每次开工前同步主仓库，避免后面 PR 冲突
git fetch upstream
git checkout main
git merge upstream/main
```

### 6.2 分支开发

```bash
git checkout -b feature/nl2sql-prompt-tune
# ... 开发、自测 ...
git add -A
git commit -m "feat(nl2sql): 在系统提示词中加入品类中英文别名映射"
git push origin feature/nl2sql-prompt-tune
```

### 6.3 PR 描述模板

```markdown
## 变更目的
（一句话说明解决什么问题，关联 Issue：Closes #12）

## 改动范围
- [ ] SQL 脚本  - [ ] Python 脚本  - [ ] 文档  - [ ] 配置

## 自测记录
- 执行的命令：
- 关键输出（贴数字，不贴"已通过"）：

## 影响面与风险
（是否影响既有指标口径？是否需要重跑全链路？）
```

### 6.4 Review 关注点（评审人用）

| 关注点 | 具体问法 |
|---|---|
| 口径 | 这个 SQL 的 GMV 带 `is_gmv_included` 了吗？ |
| 复现 | 换我机器上能跑出同样的数吗？ |
| 边界 | 空结果、单条记录、除零怎么处理？ |
| 诚实 | 不好看的结果是被修掉了，还是被藏起来了？ |
| 命名 | 表名是 `dwd_`/`dws_`/`ads_` 哪一层？符合规范吗？ |

### 6.5 冲突处理

```bash
git fetch upstream
git merge upstream/main          # 或 git rebase upstream/main
# 解决冲突后
git add <冲突文件>
git commit                       # merge 方式：保留双亲，历史可追溯
git push origin feature/nl2sql-prompt-tune
```

**原则**：冲突不要"选一边了事"，要判断两边逻辑的依赖关系；
解决后必须跑一遍验证，证明两边功能都还在（见 5.3）。

---

## 七、异常事件：`.git` 对象库损坏与恢复

这是本周真实发生的一次事故，记录在此因为它是"协同规范之外"但很现实的一课。

### 7.1 现象

依次出现三个异常：

1. 新建分支后 `git log` 报 `your current branch 'xxx' does not have any commits yet`；
2. `git cat-file -t <已知提交>` 报 `Not a valid object name`——对象不存在；
3. `git fsck` 输出大量 `missing blob`，同时 `.git/refs/heads/main` 文件消失。

### 7.2 排查过程

| 步骤 | 操作 | 结论 |
|---|---|---|
| 1 | `cat .git/HEAD` | HEAD 指向的分支引用文件不存在 → 表现为"无提交" |
| 2 | `git fsck --lost-found` | 有 dangling commit，但大量 blob `missing` → 对象库不完整，不是引用问题 |
| 3 | 手工 `echo > .git/refs/heads/probe1` 并等待 | 文件能写入且持久 → 不是权限问题，是**特定时机**被清除 |
| 4 | `git fetch origin` / `--refetch` | 引用恢复，但 `git reset` 仍读不到缺失 blob → 本地 pack 不完整 |

### 7.3 处置

工作区文件全部完好，只有 `.git` 坏了。因此采用"保留工作区、替换对象库"的做法：

```bash
# 1. 克隆一份干净的仓库（--no-checkout，不动工作区）
git clone --no-checkout git@github.com:ZYX-453/ydsh-datawarehouse.git .git_fresh

# 2. 校验克隆完整性
git -C .git_fresh fsck          # 无输出即健康
git -C .git_fresh log --oneline -1
#    df95c69 docs: 第2周验收复核……

# 3. 备份旧库后替换
mv .git <临时备份目录>/ydsh_git_corrupt_20261113
mv .git_fresh/.git .git && rmdir .git_fresh

# 4. 重建索引（工作区文件不变，第 3 周成果原样还在）
git reset
git status --short              # 第 3 周文件显示为未跟踪/已修改，重新提交
```

### 7.4 结果与代价

| 项目 | 情况 |
|---|---|
| 工作区文件 | 完整无损（docs / python / sql / output 全部在） |
| 远程历史 | 完整（`origin/main` 到 `df95c69`，第 1~2 周未受影响） |
| 本地第 3 周提交 | **全部丢失**，按原样重新提交了 8 次 |
| 耗时 | 约 25 分钟 |

### 7.5 教训

1. **push 要趁早**：如果第 3 周第一个提交后就推送，这次事故的损失会小得多。
   本次恢复后立刻执行了一次 push，之后才继续做分支演练。
2. **`.git` 不是保险箱**：工作区文件才是内容本体，`.git` 只存历史。
   出事后的正确判断顺序是"先确认工作区在不在"，而不是急着修 `.git`。
3. **环境怪癖要记下来**：本环境对 `.git/refs/heads/` 下新建**子目录**的引用文件存在丢失现象
   （`main`、`guard-bare-column` 这类扁平名不会），因此分支命名改用扁平形式。
   这类问题不能靠"重试"解决，只能靠记录规避。

---

## 八、总结

| 维度 | 本周实际做到 |
|---|---|
| Issue 追踪 | 10 条台账，全部关闭；ISSUE-08~10 是配密钥实测时才暴露的 |
| 分支 | 特性分支 1 条，含 1 次真实合并 |
| Code Review | 6 项固定清单，3 项发现全部修复，含 1 处"自己 review 自己"差点漏掉的细节 |
| 合并冲突 | 1 次真实冲突，按逻辑依赖决定顺序，5 项验证证明无损 |
| PR | 单人无法真开 PR，但提供了可直接照做的完整流程与模板 |
| 异常处置 | 1 次对象库损坏，保留工作区替换对象库，损失 8 次本地提交并重做 |
| 真实验证 | 配密钥后 6 轮实测，NL2SQL 7/7、洞察一致率 100%，修掉 3 个"通过但错"的问题 |

**最值得记的一条**：Code Review 查出最严重的问题（闸 2c 缺失），不是"代码写错了"，
而是"校验规则有盲区"——单表查询这条最常走的路径，恰恰是唯一没被覆盖的。
这也说明为什么评审清单要按"路径覆盖"而非"代码行数"来设计。

**第二条**：ISSUE-09 的教训同源，但更隐蔽——NL2SQL 报 7/7 通过，其中 1 题返回的是空表。
校验规则覆盖了"SQL 能否执行"，没覆盖"执行结果是否为空"。
**通过率是个会骗人的指标，除非它的判定条件本身是完整的。**
