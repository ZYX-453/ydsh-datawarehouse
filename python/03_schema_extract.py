"""03 — 从 Hive 自动抽取表 Schema，生成给大模型看的元信息。

为什么不用手写 schema 字典（手册步骤 5 的写法）：
    手写的那份只有 3 张表，字段还是简写；真正接 NL2SQL 时一旦表结构变了，
    字典不会跟着变，模型就会生成指向不存在字段的 SQL —— 这是 NL2SQL 最常见的翻车点。
    这里直接从 Hive Metastore 读 DESC 结果，表/字段/注释/类型全自动同步。

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


def render_prompt(schema: dict) -> str:
    lines = ["### 可用数据表（Hive）", ""]
    for full, meta in sorted(schema.items()):
        lines.append(f"**{meta['table']}**（库 {meta['database']}）— {meta['comment'] or '无表注释'}")
        for c in meta["columns"]:
            lines.append(f"  - {c['name']} {c['type']}  {c['comment']}")
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    schema = fetch_schema()
    if not schema:
        print("[ERROR] 未抽到任何表，检查 Hive 是否可用", file=sys.stderr)
        return 1

    (OUTPUT_DIR / "schema.json").write_text(
        json.dumps(schema, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    prompt = render_prompt(schema)
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
