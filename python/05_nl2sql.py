"""05 — NL2SQL：自然语言 → SQL → 执行 → 结果。

链路：
    问题 → 组装 Prompt（Schema + 口径约束 + few-shot） → LLM 生成 SQL
         → 04_sql_guard 校验（只读 / 表名 / 字段 / LIMIT）
         → 执行；若执行报错，把报错回灌给模型重试一次（自修正）
         → 返回结果表 + 最终 SQL

无密钥时的行为（重要）：
    若 .env 里没有 LLM_API_KEY，脚本进入「离线兜底模式」：
    用规则模板回答内置的 6 类典型问题，仍走同一条 guard + 执行链路。
    这样即使答辩现场断网，也能演示「提问 → SQL → 结果」的闭环，
    但会在输出里明确标注 [OFFLINE]，绝不把规则结果冒充成大模型产出。

用法：
    python 05_nl2sql.py                      # 跑内置测试集
    python 05_nl2sql.py "广东省上月销售额是多少"
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

import pandas as pd

from common import OUTPUT_DIR, load_env, query_df
from importlib import import_module

sql_guard = import_module("04_sql_guard")

load_env()

LLM_API_KEY = os.environ.get("LLM_API_KEY", "").strip()
LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "https://api.deepseek.com").strip()
LLM_MODEL = os.environ.get("LLM_MODEL", "deepseek-chat").strip()

SYSTEM_PROMPT = """你是企业数据仓库的 Hive SQL 专家。把用户的中文问题翻译成一条可执行的 Hive SQL。

硬性规则：
1. 只能输出 SELECT 语句，禁止 INSERT/UPDATE/DELETE/DROP/ALTER/TRUNCATE/CREATE。
2. 只能使用下面列出的表和字段，不要编造。特别注意：
   - dwd_order 没有 product_id / quantity，商品信息必须经 dwd_order_item 关联 dim_product。
   - 订单明细表 dwd_order_item 的 item_amount 是吊牌价口径，总额约 2.66 亿；
     GMV 必须用 dwd_order.pay_amount，两者不能相加或混用。
3. GMV 口径：统计成交金额必须带 `is_gmv_included = 1`；
   若查的是 ads_* / dws_* 层的指标字段（gmv、sales_amt），这些表已按口径过滤，不要再加条件。
4. 优先查 ads_* 层（面向业务的成品指标），需要下钻时再查 dws_* / dwd_*。
5. 金额字段是 DOUBLE，需要两位小数时用 cast(x as decimal(18,2))，不要用 round(double,n)（本引擎会返回 NULL）。
6. 结果行数可能很大时加 LIMIT，最多 200 行。
7. 日期字段：order_date / stat_date 是 'yyyy-MM-dd' 字符串，年月用 substr(stat_date,1,7)。
8. 只输出 SQL，不要输出解释、不要加 markdown 代码围栏。

{例子}

{schema}"""

FEW_SHOT = """示例 1：
问：广东省上个月的销售额是多少
答：
SELECT cast(sum(gmv) as decimal(18,2)) AS gmv
FROM ydsh_ads.ads_region_rank
WHERE province = '广东省'
LIMIT 10

示例 2：
问：销量最高的前 5 个品类
答：
SELECT rk, category, cast(sales_amt as decimal(18,2)) AS sales_amt, order_cnt
FROM ydsh_ads.ads_category_rank
ORDER BY rk
LIMIT 5

示例 3：
问：2024 年 6 月的 GMV 和环比
答：
SELECT stat_ym, cast(gmv as decimal(18,2)) AS gmv, cast(gmv_mom as decimal(8,4)) AS gmv_mom
FROM ydsh_ads.ads_kpi_month
WHERE stat_ym = '2024-06'
LIMIT 10

示例 4：
问：复购率是多少
答：
SELECT cast(gmv as decimal(18,2)) AS gmv, order_cnt, cast(repurchase_rate as decimal(8,4)) AS repurchase_rate
FROM ydsh_ads.ads_kpi_overview
LIMIT 10"""


def load_schema_prompt() -> str:
    p = OUTPUT_DIR / "schema_prompt.md"
    if not p.exists():
        raise SystemExit("缺少 output/schema_prompt.md，先跑 python 03_schema_extract.py")
    return p.read_text(encoding="utf-8")


# ---------------------------------------------------------------- LLM ----
def llm_generate(question: str, schema_prompt: str, hint: str = "") -> str:
    from openai import OpenAI

    client = OpenAI(api_key=LLM_API_KEY, base_url=LLM_BASE_URL)
    system = SYSTEM_PROMPT.replace("{例子}", FEW_SHOT).replace("{schema}", schema_prompt)
    user = f"问题：{question}"
    if hint:
        user += f"\n\n上一次生成的 SQL 执行失败，错误信息：\n{hint}\n请修正后重新输出 SQL。"
    resp = client.chat.completions.create(
        model=LLM_MODEL,
        messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
        temperature=0,
    )
    text = resp.choices[0].message.content or ""
    return clean_sql(text)


def clean_sql(text: str) -> str:
    """剥掉模型爱加的 markdown 围栏和前缀说明。"""
    text = text.strip()
    m = re.search(r"```(?:sql)?\s*(.*?)```", text, re.S | re.I)
    if m:
        text = m.group(1).strip()
    # 去掉「答：」「SQL：」之类的引导词
    text = re.sub(r"^\s*(答|SQL|sql)\s*[:：]\s*", "", text)
    # 只保留第一条语句
    parts = [p for p in text.split(";") if p.strip()]
    return (parts[0].strip() + "") if parts else ""


# ---------------------------------------------------------------- 离线兜底 ----
def offline_generate(question: str) -> str:
    """无密钥时的规则兜底。明确只覆盖 6 类问题，覆盖不到就返回空串。"""
    q = question.strip()

    province_match = re.search(r"(北京|上海|天津|重庆|浙江|湖南|四川|辽宁|陕西|江苏|河南|福建|山东|湖北|安徽|广东)省?", q)
    month_match = re.search(r"(\d{1,2})\s*月", q)

    if province_match and ("销售" in q or "GMV" in q.upper() or "gmv" in q):
        prov = province_match.group(0)
        if not prov.endswith("省") and prov not in ("北京", "上海", "天津", "重庆"):
            prov += "省"
        if "上" in q and "月" in q:
            return (
                "SELECT stat_ym, cast(sum(gmv) as decimal(18,2)) AS gmv, sum(order_cnt) AS order_cnt "
                f"FROM ydsh_dws.dws_store_month WHERE province = '{prov}' "
                "AND stat_ym = (SELECT max(stat_ym) FROM ydsh_dws.dws_store_month) "
                "GROUP BY stat_ym LIMIT 10"
            )
        return (
            f"SELECT cast(sum(gmv) as decimal(18,2)) AS gmv, sum(order_cnt) AS order_cnt "
            f"FROM ydsh_dws.dws_store_month WHERE province = '{prov}' LIMIT 10"
        )

    if ("品类" in q or "类目" in q) and ("前" in q or "top" in q.lower() or "最高" in q):
        n = re.search(r"前\s*(\d+)", q)
        k = int(n.group(1)) if n else 5
        return (
            "SELECT rk, category, cast(sales_amt as decimal(18,2)) AS sales_amt, "
            "cast(sales_share as decimal(8,4)) AS sales_share, order_cnt "
            f"FROM ydsh_ads.ads_category_rank ORDER BY rk LIMIT {k}"
        )

    if "复购" in q:
        return ("SELECT cast(gmv as decimal(18,2)) AS gmv, order_cnt, repurchase_users, "
                "cast(repurchase_rate as decimal(8,4)) AS repurchase_rate FROM ydsh_ads.ads_kpi_overview LIMIT 10")

    if month_match and ("gmv" in q.lower() or "销售" in q):
        m = int(month_match.group(1))
        return (
            "SELECT stat_ym, cast(gmv as decimal(18,2)) AS gmv, "
            "cast(gmv_mom as decimal(8,4)) AS gmv_mom "
            f"FROM ydsh_ads.ads_kpi_month WHERE stat_ym = '2024-{m:02d}' LIMIT 10"
        )

    if "门店" in q and ("前" in q or "top" in q.lower()):
        n = re.search(r"前\s*(\d+)", q)
        k = int(n.group(1)) if n else 10
        return ("SELECT rk, store_name, province, cast(gmv as decimal(18,2)) AS gmv, order_cnt "
                f"FROM ydsh_ads.ads_store_top10 ORDER BY rk LIMIT {k}")

    if "分层" in q or "价值" in q or "RFM" in q.upper() or "rfm" in q:
        return ("SELECT segment, user_cnt, cast(gmv as decimal(18,2)) AS gmv, "
                "cast(gmv_share as decimal(8,4)) AS gmv_share FROM ydsh_ads.ads_user_value "
                "ORDER BY gmv DESC LIMIT 20")

    if "gmv" in q.lower() or "总额" in q or "总销售" in q:
        return ("SELECT stat_scope, cast(gmv as decimal(18,2)) AS gmv, order_cnt, "
                "cast(aov as decimal(18,2)) AS aov, active_users FROM ydsh_ads.ads_kpi_overview LIMIT 10")

    return ""


# ---------------------------------------------------------------- 主链路 ----
def ask(question: str, retry_on_error: bool = True) -> dict:
    schema_prompt = load_schema_prompt()
    mode = "LLM" if LLM_API_KEY else "OFFLINE"

    if mode == "LLM":
        try:
            sql = llm_generate(question, schema_prompt)
        except Exception as e:                     # 网络/额度问题不阻断演示
            return {"question": question, "mode": mode, "ok": False, "error": f"LLM 调用失败: {e}",
                    "sql": "", "rows": None}
    else:
        sql = offline_generate(question)
        if not sql:
            return {"question": question, "mode": mode, "ok": False,
                    "error": "离线兜底模式未覆盖该问题（配置 LLM_API_KEY 后可自由提问）",
                    "sql": "", "rows": None}

    ok, sql_checked, warns = sql_guard.validate(sql)
    if not ok:
        return {"question": question, "mode": mode, "ok": False, "error": "; ".join(warns),
                "sql": sql, "rows": None}

    try:
        df = query_df(sql_checked, "ydsh_ads")
    except Exception as e:
        if retry_on_error and mode == "LLM":
            try:
                sql2 = llm_generate(question, schema_prompt, hint=str(e))
                ok2, sql2_checked, warns2 = sql_guard.validate(sql2)
                if ok2:
                    df = query_df(sql2_checked, "ydsh_ads")
                    return {"question": question, "mode": mode + "+自修正", "ok": True,
                            "error": "", "sql": sql2_checked, "rows": df, "warns": warns2}
            except Exception as e2:
                e = e2
        return {"question": question, "mode": mode, "ok": False, "error": f"执行失败: {e}",
                "sql": sql_checked, "rows": None}

    return {"question": question, "mode": mode, "ok": True, "error": "",
            "sql": sql_checked, "rows": df, "warns": warns}


TEST_QUESTIONS = [
    "2024 年全年 GMV 是多少，订单量和客单价呢",
    "广东省上个月的销售额是多少",
    "销量最高的前 5 个品类",
    "复购率是多少",
    "2024 年 6 月的 GMV 和环比",
    "门店销售额前 5 名",
    "用户价值分层各层占比",
]


def main() -> int:
    mode = "LLM" if LLM_API_KEY else "OFFLINE（未配置 LLM_API_KEY，使用规则兜底）"
    print(f"模式: {mode}")
    print(f"模型: {LLM_MODEL} @ {LLM_BASE_URL}" if LLM_API_KEY else "")

    questions = sys.argv[1:] or TEST_QUESTIONS
    records = []
    for q in questions:
        print("\n" + "=" * 78)
        print(f"问：{q}")
        r = ask(q)
        if not r["ok"]:
            print(f"[FAIL/{r['mode']}] {r['error']}")
            records.append({"question": q, "mode": r["mode"], "ok": False,
                            "sql": r.get("sql", ""), "error": r["error"], "rows": 0})
            continue
        print(f"SQL（{r['mode']}）:\n{r['sql']}")
        if r.get("warns"):
            print(f"告警: {'; '.join(r['warns'])}")
        df = r["rows"]
        print(f"结果（{len(df)} 行）:")
        print(df.head(10).to_string(index=False))
        records.append({"question": q, "mode": r["mode"], "ok": True,
                        "sql": r["sql"].replace("\n", " "), "error": "", "rows": len(df)})

    out = OUTPUT_DIR / f"nl2sql_results_{'llm' if LLM_API_KEY else 'offline'}.csv"
    pd.DataFrame(records).to_csv(out, index=False, encoding="utf-8-sig")
    ok_cnt = sum(1 for r in records if r["ok"])
    print("\n" + "=" * 78)
    print(f"通过 {ok_cnt}/{len(records)} 题，明细已写入 {out}")
    return 0 if ok_cnt == len(records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
