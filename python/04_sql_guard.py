"""04 — SQL 安全校验与修正（NL2SQL 的「刹车」）。

大模型生成的 SQL 不能直接拿去跑，必须先过三道闸：
    1. 只允许 SELECT：出现 INSERT/UPDATE/DELETE/DROP/ALTER/TRUNCATE 一律拒绝
    2. 表名/字段名必须存在于抽取到的 Schema 中：防止模型编造 product_id 之类的字段
       （本项目 dwd_order 真的没有 product_id，模型极爱这么写）
    3. 强制补 LIMIT：防止「查全表」把 6 万行行为数据整出来

这一层是纯规则实现，可离线单测，不依赖大模型。
用法：
    python 04_sql_guard.py            # 跑内置用例
"""
from __future__ import annotations

import json
import re
import sys

from common import OUTPUT_DIR

WRITE_KEYWORDS = (
    "insert", "update", "delete", "drop", "alter", "truncate",
    "create", "grant", "revoke", "load", "msck", "set",
)
DEFAULT_LIMIT = 200
MAX_LIMIT = 1000        # 超过此值的 LIMIT 只告警不拦截：可能确有导出需求


def load_schema() -> dict:
    path = OUTPUT_DIR / "schema.json"
    if not path.exists():
        raise SystemExit("缺少 output/schema.json，先跑 python 03_schema_extract.py")
    return json.loads(path.read_text(encoding="utf-8"))


def _strip_comments(sql: str) -> str:
    sql = re.sub(r"--[^\n]*", " ", sql)
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    return sql


def _strip_literals(sql: str) -> str:
    """把字符串字面量替换为空串。

    为什么需要：关键字扫描是纯文本匹配，`where stat_scope = 'a drop test'`
    会因为字面量里出现 drop 被误判成写操作而拒绝执行。
    用户查的数据内容不该影响语句合法性判断，所以扫描前先把字面量摘掉。
    """
    return re.sub(r"'(?:[^']|'')*'", "''", sql)


def _normalise_table(token: str, schema: dict) -> str | None:
    """把 `tbl` / `db.tbl` / `db`.`tbl` 归一到 schema 的键。"""
    t = token.replace("`", "").strip().lower()
    if "." in t:
        return t if t in schema else None
    hits = [k for k, v in schema.items() if v["table"].lower() == t]
    return hits[0] if len(hits) == 1 else None


def _column_pool(schema: dict, tables: list[str]) -> set[str]:
    pool = set()
    for t in tables:
        pool.update(c["name"].lower() for c in schema[t]["columns"])
    return pool


# 别名捕获时会把 WHERE / ON / GROUP 之类的关键字误当成别名，必须显式排除
SQL_KEYWORDS = {
    "where", "on", "group", "order", "limit", "having", "join", "inner", "left",
    "right", "full", "cross", "union", "select", "as", "and", "or", "using", "with",
}


def _cte_names(clean: str) -> set[str]:
    """提取 CTE 名：`WITH a AS (` 与 `, b AS (` 两种写法。"""
    return set(re.findall(r"(?:with|,)\s+([a-z_]\w*)\s+as\s*\(", clean))


def _alias_map(clean: str, schema: dict) -> dict[str, str]:
    """建立 别名 → 真实表 的映射，用于逐表校验字段。

    只做「池化校验」是不够的：dwd_order 与 dim_product 的字段池合并后，
    `o.product_id`（o 是 dwd_order）会因为 dim_product 有 product_id 而被放过，
    而这恰恰是部署手册里那个必踩的错。
    """
    amap: dict[str, str] = {}
    for m in re.finditer(
        r"\b(?:from|join)\s+([`\w]+(?:\s*\.\s*[`\w]+)?)(?:\s+(?:as\s+)?([a-z_]\w*))?", clean
    ):
        tbl_tok, alias = m.group(1), m.group(2)
        key = _normalise_table(re.sub(r"\s+", "", tbl_tok), schema)
        if key is None:
            continue
        if alias and alias not in SQL_KEYWORDS:
            amap[alias] = key
        # 没写别名时，用表名本身当引用名
        amap.setdefault(key.split(".")[-1], key)
    return amap


def validate(sql: str, schema: dict | None = None) -> tuple[bool, str, list[str]]:
    """返回 (是否通过, 处理后的SQL, 告警列表)。"""
    schema = schema or load_schema()
    warns: list[str] = []
    raw = sql.strip().strip(";").strip()

    clean = _strip_comments(raw).lower()

    # 闸 1：只读
    #   先摘掉字符串字面量再扫关键字：`where x = 'a drop test'` 里没有写操作
    for kw in WRITE_KEYWORDS:
        if re.search(rf"(^|[\s(;]){kw}\b", _strip_literals(clean)):
            return False, raw, [f"包含非只读关键字 `{kw.upper()}`，已拒绝执行"]

    if not re.match(r"^(with|select)\b", clean):
        return False, raw, ["语句不是以 SELECT / WITH 开头"]

    # 闸 2：表名必须在 Schema 内
    #   FROM / JOIN 后面允许三种形态：db.tbl、tbl、`db`.`tbl`
    #   CTE 名（WITH x AS ...）是查询内临时表，不算非法表
    cte = _cte_names(clean)
    found = re.findall(r"\b(?:from|join)\s+([`\w]+(?:\s*\.\s*[`\w]+)?)", clean)
    resolved: list[str] = []
    for f in found:
        name = re.sub(r"\s+", "", f).replace("`", "").lower()
        if name in cte:
            continue
        key = _normalise_table(name, schema)
        if key is None:
            return False, raw, [f"表 `{f}` 不在 Schema 中（模型可能编造了表名）"]
        resolved.append(key)
    if not resolved:
        return False, raw, ["未识别到任何真实表（只有 CTE 或没有 FROM）"]
    if len(set(resolved)) > 6:
        warns.append(f"涉及 {len(set(resolved))} 张表，连接可能过重")

    # 闸 2b：字段校验——先按别名绑定到具体表，再查该表字段
    amap = _alias_map(clean, schema)
    for alias, col in re.findall(r"\b([a-z_]\w*)\.([a-z_]\w*)\b", clean):
        if col == "*":
            continue
        table = amap.get(alias)
        if table is None:                      # 子查询/CTE 的别名，无法静态判定，放过
            continue
        cols = {c["name"].lower() for c in schema[table]["columns"]}
        if col not in cols:
            return False, raw, [
                f"字段 `{alias}.{col}` 不存在于 {table}（该表字段：{', '.join(sorted(cols))[:120]}）"
            ]

    # 闸 3：补 LIMIT，并对过大的 LIMIT 告警
    #   补 LIMIT 是为了防止「查全表」；反过来，模型偶尔会写 LIMIT 100000 这种，
    #   在 Hive 上等于把结果全拉回客户端，同样要提示。
    sql_out = raw
    lim = re.search(r"\blimit\s+(\d+)", clean)
    if lim is None:
        sql_out = f"{raw}\nLIMIT {DEFAULT_LIMIT}"
        warns.append(f"未写 LIMIT，已自动补 LIMIT {DEFAULT_LIMIT}")
    elif int(lim.group(1)) > MAX_LIMIT:
        warns.append(f"LIMIT {lim.group(1)} 超过建议上限 {MAX_LIMIT}，Hive 侧返回大结果集会明显变慢")

    return True, sql_out, warns


CASE_SQL_BAD = [
    ("DELETE FROM dwd_order", "写操作"),
    ("select * from dwd_order o join dim_product p on o.product_id = p.product_id",
     "dwd_order 没有 product_id（手册里的经典错误）"),
    ("select sum(pay_amount) from ods_order where order_date like '2024/1%'",
     "ods_order 未对模型开放"),
    ("select sum(pay_amount) from dwd_order where is_gmv_included=1", "缺 LIMIT，应补"),
    ("select store_name, sum(gmv) from dws_store_month group by store_name", "合法"),
]

CASE_SQL_OK = [
    ("SELECT category, sales_amt FROM ads_category_rank ORDER BY sales_amt DESC LIMIT 5", True),
    ("SELECT sum(gmv) FROM ads_kpi_overview", True),
    ("WITH t AS (SELECT stat_date, gmv FROM ads_sales_daily) SELECT * FROM t", True),
    ("DROP TABLE dwd_order", False),
    ("SELECT * FROM ads_sales_daily", True),
    # 回归用例：字面量里出现写操作关键字，不应被误判
    ("SELECT * FROM ads_kpi_overview WHERE stat_scope = 'a drop test' LIMIT 3", True),
]


def main() -> int:
    schema = load_schema()
    print("=== 反例（应被拦截或告警）===")
    for sql, why in CASE_SQL_BAD:
        ok, out, warns = validate(sql, schema)
        flag = "通过" if ok else "拦截"
        tail = warns[0] if warns else "—"
        print(f"[{flag}] {why}\n        {tail}")

    print("\n=== 用例（合法性断言）===")
    failed = 0
    for sql, expect in CASE_SQL_OK:
        ok, out, warns = validate(sql, schema)
        mark = "OK " if ok == expect else "FAIL"
        if ok != expect:
            failed += 1
        print(f"[{mark}] 期望{'通过' if expect else '拦截'} 实际{'通过' if ok else '拦截'} :: {sql[:60]}")

    print(f"\n断言失败 {failed} 项")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
