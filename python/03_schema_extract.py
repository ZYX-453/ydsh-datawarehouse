"""03 — 从 Hive 自动抽取表 Schema，生成给大模型看的元信息。

为什么不用手写 schema 字典（手册步骤 5 的写法）：
    手写的那份只有 3 张表，字段还是简写；真正接 NL2SQL 时一旦表结构变了，
    字典不会跟着变，模型就会生成指向不存在字段的 SQL —— 这是 NL2SQL 最常见的翻车点。
    这里直接从 Hive Metastore 读 DESC 结果，表/字段/注释/类型全自动同步。

为什么还要额外采样「枚举取值」：
    字段注释是人写的，经常和真实数据不一致。曾实测到 ads_kpi_overview.stat_scope
    的注释是「统计口径范围，如 2024 全年」，而库里真实值只有一条
    「2024 全年（成交口径）」；模型照抄注释去 WHERE stat_scope='2024全年'，
    SQL 语法完全合法、执行不报错、返回 0 行 —— 这类「静默错误」比报错更难发现。
    所以对低基数列（distinct <= ENUM_MAX_CARDINALITY）直接采样真实取值写进 Prompt，
    让模型「看数据」而不是「猜注释」。

输出：
    output/schema.json        结构化（供程序校验 SQL 合法性）
    output/schema_prompt.md   渲染成 Prompt 用的文本块
用法：
    python 03_schema_extract.py
"""
from __future__ import annotations

import json
import re
import sys

from common import HIVE_DB, OUTPUT_DIR, get_hive_conn

# 枚举采样参数：distinct 数不超过它才认为是「枚举列」，值得写进 Prompt
ENUM_MAX_CARDINALITY = 12
# 单表行数上限：超过就不拉全量（大表拉回来只为算 distinct，性价比太低）
ENUM_MAX_ROWS = 20000

# 只暴露「面向分析」的层。ODS 是原始脏数据、DWD 是明细，直接查 ODS 会得到脏结果；
# 但 NL2SQL 又必须能下钻到 DWD 维度表做关联，所以三层都开放，ODS 排除。
DATABASES = ["ydsh_ads", "ydsh_dws", "ydsh_dwd"]

# 内部中间表/实验表不给模型看，避免它一本正经地查 stg_ / tmp_ / 分桶实验表
EXCLUDE_PREFIX = ("stg_", "tmp_")
EXCLUDE_TABLES = {
    "dwd_order_bucket",   # 第 2 周分桶实验表，与 dwd_order 内容重复
    "eda_user_month",     # 第 2 周 EDA 的临时结果表
    "quality_compare",    # 数据质量对比表，不是业务表
}


def fetch_schema() -> dict:
    conn = get_hive_conn("default")
    cur = conn.cursor()
    schema: dict[str, dict] = {}
    try:
        for db in DATABASES:
            cur.execute(f"SHOW TABLES IN {db}")
            tables = [r[0] for r in cur.fetchall()]
            for t in tables:
                if t.startswith(EXCLUDE_PREFIX) or t in EXCLUDE_TABLES:
                    continue
                cur.execute(f"DESCRIBE {db}.{t}")
                cols, comment = [], ""
                in_partition = False
                for row in cur.fetchall():
                    name = (row[0] or "").strip()
                    if not name:
                        continue
                    if name.startswith("# Partition Information"):
                        in_partition = True
                        continue
                    if name.startswith("#"):
                        continue
                    dtype = (row[1] or "").strip()
                    cmt = (row[2] or "").strip() if len(row) > 2 else ""
                    if in_partition:
                        cmt = (cmt + " [分区键]").strip()
                    cols.append({"name": name, "type": dtype, "comment": cmt})
                # 表注释单独取
                cur.execute(f"DESCRIBE FORMATTED {db}.{t}")
                for row in cur.fetchall():
                    if row[0] and "Table Parameters" in str(row[0]):
                        break
                    if row[0] and str(row[0]).strip() == "comment":
                        comment = (row[1] or "").strip()
                        break
                schema[f"{db}.{t}"] = {"database": db, "table": t, "comment": comment, "columns": cols}
    finally:
        conn.close()
    return schema


def _in_enum_scope(full: str) -> bool:
    """决定哪些表值得做枚举采样。

    ADS 层是业务成品表，枚举过滤几乎都发生在这一层；
    dim_* 是维度表，天然全是枚举；dws_* 是汇总层，量也小。
    dwd_* 事实表体量大、列基数高，采样收益低，跳过以控制耗时。
    """
    db, _, table = full.partition(".")
    if db == "ydsh_ads":
        return True
    if table.startswith("dim_"):
        return True
    return db == "ydsh_dws"


def sample_enums(schema: dict) -> dict[str, dict[str, list[str]]]:
    """对低基数字符串列采样真实取值。

    一次 SELECT * 拉回整表在本地算 distinct，比逐列发 GROUP BY 快得多
    （后者每列一个 Tez 作业，几十秒起步）。表行数受 ENUM_MAX_ROWS 保护。
    """
    from collections import Counter

    result: dict[str, dict[str, list[str]]] = {}
    conn = get_hive_conn("default")
    cur = conn.cursor()
    try:
        for full, meta in sorted(schema.items()):
            if not _in_enum_scope(full):
                continue
            str_cols = [c["name"] for c in meta["columns"] if c["type"] == "string"]
            if not str_cols:
                continue
            try:
                cur.execute(f"SELECT count(1) FROM {full}")
                n = cur.fetchone()[0]
                if not n or n > ENUM_MAX_ROWS:
                    continue
                cur.execute(f"SELECT * FROM {full}")
                rows = cur.fetchall()
                cols = [d[0].split(".")[-1] for d in cur.description]
            except Exception as e:                      # 单表失败不影响整体抽取
                print(f"  [WARN] {full} 枚举采样跳过: {type(e).__name__}: {e}")
                continue

            idx = {c: i for i, c in enumerate(cols)}
            percol: dict[str, list[str]] = {}
            for c in str_cols:
                if c not in idx:
                    continue
                vals = Counter(str(r[idx[c]]) for r in rows if r[idx[c]] is not None)
                # 只保留「基数低且非空」的列；空串当作缺失丢弃
                if 0 < len(vals) <= ENUM_MAX_CARDINALITY:
                    keys = [v for v, _ in vals.most_common() if v.strip() != ""]
                    if keys:
                        percol[c] = keys
            if percol:
                result[full] = percol
    finally:
        conn.close()
    return result


def render_prompt(schema: dict, enums: dict[str, dict[str, list[str]]] | None = None) -> str:
    enums = enums or {}
    lines = ["### 可用数据表（Hive）", ""]
    for full, meta in sorted(schema.items()):
        lines.append(f"**{meta['table']}**（库 {meta['database']}）— {meta['comment'] or '无表注释'}")
        for c in meta["columns"]:
            lines.append(f"  - {c['name']} {c['type']}  {c['comment']}")
            vals = enums.get(full, {}).get(c["name"])
            if vals:
                shown = "、".join(f"'{v}'" for v in vals)
                lines.append(f"      ※ 该列实际取值（必须原样使用，勿改写或简写）：{shown}")
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    schema = fetch_schema()
    if not schema:
        print("[ERROR] 未抽到任何表，检查 Hive 是否可用", file=sys.stderr)
        return 1

    print("采样枚举取值 ...")
    enums = sample_enums(schema)
    enum_cols = sum(len(v) for v in enums.values())
    print(f"  命中 {len(enums)} 张表 / {enum_cols} 个枚举列")
    for full, cols in sorted(enums.items()):
        for c, vals in cols.items():
            print(f"  {full}.{c}: {len(vals)} 个取值")

    # 枚举值随 schema 一起落盘，供 04_sql_guard 校验字面量是否真实存在
    payload = {full: {**meta, "enums": enums.get(full, {})} for full, meta in schema.items()}
    (OUTPUT_DIR / "schema.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    prompt = render_prompt(schema, enums)
    (OUTPUT_DIR / "schema_prompt.md").write_text(prompt, encoding="utf-8")

    tables = len(schema)
    cols = sum(len(m["columns"]) for m in schema.values())
    print(f"抽取完成：{tables} 张表 / {cols} 个字段")
    for db in DATABASES:
        names = [m["table"] for m in schema.values() if m["database"] == db]
        print(f"  {db:<10} {len(names):>2} 张：{', '.join(sorted(names))}")
    print(f"输出: {OUTPUT_DIR / 'schema.json'}")
    print(f"输出: {OUTPUT_DIR / 'schema_prompt.md'}（{len(prompt)} 字符）")

    # 自检：确认排除规则生效
    leaked = [k for k in schema if re.search(r"\.(stg_|tmp_)", k)]
    print(f"自检: 中间表泄漏 {len(leaked)} 张" + (f" -> {leaked}" if leaked else " ✓"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
