"""07 — AI 智能洞察：异常检测 + 大模型归因 + 自动报告 + 事实校验。

流程：
    1. 从 ADS 读指标，算「异常」：日 GMV 相对 7 日移动平均的偏离（z 分数）
    2. 把异常事实整理成结构化证据（evidence dict），只给模型「事实」，不给结论
    3. 调用大模型做归因与建议；无密钥时用规则化模板生成同结构的报告
    4. 事实校验：把 AI 文本里的数字逐个拿去和证据比对，输出「有据 / 无据」比例
       —— 这一步是本脚本的核心。大模型最容易「编一个看起来很合理的百分比」，
          不校验就写进报告，等于把幻觉当分析结论。

输出：
    output/ai_insight_report.md    自动经营分析摘要（含校验结果）
    output/insight_evidence.json   证据事实（可复算）
用法：
    python 07_ai_insight.py
"""
from __future__ import annotations

import json
import os
import re
from datetime import datetime

import numpy as np
import pandas as pd

from common import OUTPUT_DIR, load_env, query_df

load_env()

KEY = os.environ.get("LLM_API_KEY", "").strip()
BASE_URL = os.environ.get("LLM_BASE_URL", "https://api.deepseek.com")
MODEL = os.environ.get("LLM_MODEL", "deepseek-chat")


# ---------------------------------------------------------------- 1. 事实 ----
def build_evidence() -> dict:
    daily = pd.read_csv(OUTPUT_DIR / "daily_gmv.csv", parse_dates=["stat_date"]).sort_values("stat_date")
    monthly = pd.read_csv(OUTPUT_DIR / "monthly_kpi.csv")
    kpi = query_df("SELECT * FROM ads_kpi_overview", "ydsh_ads").iloc[0]
    cat = query_df("SELECT * FROM ads_category_rank ORDER BY rk", "ydsh_ads")
    region = query_df("SELECT * FROM ads_region_rank ORDER BY rk", "ydsh_ads")
    seg = query_df("SELECT * FROM ads_user_value ORDER BY gmv DESC", "ydsh_ads")
    funnel = query_df("SELECT * FROM ads_behavior_funnel ORDER BY step", "ydsh_ads")

    # 异常：相对 7 日移动平均（用 shift(1) 避免当天进入基线）
    daily["baseline"] = daily["gmv"].shift(1).rolling(7, min_periods=4).mean()
    daily["resid"] = daily["gmv"] - daily["baseline"]
    daily["resid_pct"] = daily["resid"] / daily["baseline"]
    std = daily["resid"].std()
    daily["z"] = daily["resid"] / std if std else 0

    valid = daily.dropna(subset=["baseline"])
    worst = valid.nsmallest(3, "resid_pct")
    best = valid.nlargest(3, "resid_pct")

    wd_mean = daily.groupby(daily["stat_date"].dt.day_of_week + 1)["gmv"].mean()
    wd_ratio = float(wd_mean.max() / wd_mean.min())

    ev = {
        "周期": f"{daily['stat_date'].min():%Y-%m-%d} ~ {daily['stat_date'].max():%Y-%m-%d}",
        "GMV": round(float(kpi["gmv"]), 2),
        "订单量": int(kpi["order_cnt"]),
        "客单价": round(float(kpi["aov"]), 2),
        "成交用户数": int(kpi["active_users"]),
        "复购率": round(float(kpi["repurchase_rate"]), 4),
        "日均GMV": round(float(daily["gmv"].mean()), 2),
        "日GMV标准差": round(float(daily["gmv"].std()), 2),
        "日GMV变异系数": round(float(daily["gmv"].std() / daily["gmv"].mean()), 4),
        "周内效应倍数": round(wd_ratio, 4),
        "最大单日跌幅": round(float(worst["resid_pct"].min()), 4),
        "跌幅最大日期": [(f"{r.stat_date:%Y-%m-%d}", round(float(r.resid_pct), 4)) for r in worst.itertuples()],
        "最大单日涨幅": round(float(best["resid_pct"].max()), 4),
        "涨幅最大日期": [(f"{r.stat_date:%Y-%m-%d}", round(float(r.resid_pct), 4)) for r in best.itertuples()],
        "环比跌幅最大月": monthly.loc[monthly["gmv_mom"].idxmin(), "stat_ym"],
        "最大月度环比": round(float(monthly["gmv_mom"].min()), 4),
        "月度GMV极差率": round(float((monthly["gmv"].max() - monthly["gmv"].min()) / monthly["gmv"].max()), 4),
        "TOP1品类": cat.iloc[0]["category"],
        "TOP1品类销售额": round(float(cat.iloc[0]["sales_amt"]), 2),
        "TOP1品类占比": round(float(cat.iloc[0]["sales_share"]), 4),
        "TOP3品类合计占比": round(float(cat.head(3)["sales_share"].sum()), 4),
        "TOP1省份": region.iloc[0]["province"],
        "TOP1省份GMV": round(float(region.iloc[0]["gmv"]), 2),
        "TOP1省份占比": round(float(region.iloc[0]["gmv_share"]), 4),
        "TOP3省份合计占比": round(float(region.head(3)["gmv_share"].sum()), 4),
        "最高价值层": seg.iloc[0]["segment"],
        "最高价值层人数": int(seg.iloc[0]["user_cnt"]),
        "最高价值层GMV占比": round(float(seg.iloc[0]["gmv_share"]), 4),
        "行为漏斗": {r.behavior_type: int(r.event_cnt) for r in funnel.itertuples()},
    }
    return ev, daily, monthly


# ---------------------------------------------------------------- 2. 归因 ----
RULE_CAUSES = [
    "模拟数据由随机过程生成，日 GMV 无趋势与季节性结构（变异系数 {cv:.3f}，"
    "周内最强/最弱仅 {wd:.3f} 倍），单日涨跌属于抽样噪声，不具备业务归因价值。",
    "若为真实数据，优先排查：大促/发券等活动节奏、渠道投放变化、支付通道异常、"
    "数据延迟导致的订单未落库。",
    "品类与省份集中度低（TOP1 品类 {c1:.1%}、TOP1 省份 {r1:.1%}），"
    "说明没有单一爆品或单一区域能解释整体波动。",
]


def rule_report(ev: dict) -> str:
    return f"""## 一、整体经营状况

统计周期 {ev['周期']}，全年 GMV **{ev['GMV']:,.2f} 元**，订单量 **{ev['订单量']:,} 单**，
客单价 **{ev['客单价']:,.2f} 元**，成交用户 **{ev['成交用户数']:,} 人**，复购率 **{ev['复购率']:.1%}**，
日均 GMV {ev['日均GMV']:,.2f} 元。

## 二、异常识别

- 单日最大跌幅 **{ev['最大单日跌幅']:.2%}**（{ev['跌幅最大日期'][0][0]}），
  相对 7 日移动平均的偏离；最大涨幅 **{ev['最大单日涨幅']:.2%}**（{ev['涨幅最大日期'][0][0]}）。
- 月度层面，环比跌幅最大的是 **{ev['环比跌幅最大月']}（{ev['最大月度环比']:.2%}）**；
  全年月度 GMV 极差率仅 **{ev['月度GMV极差率']:.2%}**，无趋势性下滑。
- 日 GMV 变异系数 **{ev['日GMV变异系数']:.3f}**，处于随机波动区间（<0.35）。

## 三、归因判断（规则生成，未经大模型）

1. {RULE_CAUSES[0].format(cv=ev['日GMV变异系数'], wd=ev['周内效应倍数'])}
2. {RULE_CAUSES[1]}
3. {RULE_CAUSES[2].format(c1=ev['TOP1品类占比'], r1=ev['TOP1省份占比'])}

## 四、结构洞察

- 品类：TOP1 为 **{ev['TOP1品类']}**，销售额 {ev['TOP1品类销售额']:,.2f} 元（占比 {ev['TOP1品类占比']:.2%}），
  TOP3 合计 {ev['TOP3品类合计占比']:.2%}，结构分散，无单品依赖。
- 区域：**{ev['TOP1省份']}** 以 {ev['TOP1省份GMV']:,.2f} 元居首（占比 {ev['TOP1省份占比']:.2%}），
  TOP3 省份合计 {ev['TOP3省份合计占比']:.2%}。
- 用户：**{ev['最高价值层']}** {ev['最高价值层人数']:,} 人，贡献 {ev['最高价值层GMV占比']:.2%} 的 GMV，
  符合「二八分布」的典型形态。

## 五、行动建议

1. 数据侧：当前数据无季节性，任何「同比/环比归因」都缺乏统计支撑，
   建议先补齐连续两年的数据再谈趋势。
2. 经营侧：把资源集中在 {ev['TOP1品类']} 与 {ev['TOP1省份']} 的存量优势，
   同时用 RFM 的「重要挽留」人群做召回，其人均消费不低于整体均值。
3. 监控侧：单日跌幅超过 15% 才触发告警，低于该阈值应视为噪声，避免告警疲劳。
"""


def llm_report(ev: dict) -> tuple[str, str]:
    from openai import OpenAI

    client = OpenAI(api_key=KEY, base_url=BASE_URL)
    system = (
        "你是零售企业的数据分析师。基于给定的 JSON 事实写一份中文经营分析摘要。\n"
        "铁律：\n"
        "1. 只能使用 JSON 中出现的数字，禁止自行推算或编造任何百分比、金额、日期。\n"
        "2. 若某项归因缺乏数据支撑，必须明说「数据不足，无法判断」，不得给出确定性因果结论。\n"
        "3. 输出 Markdown，包含：整体经营状况 / 异常识别 / 归因判断（含不确定性说明）/ 结构洞察 / 行动建议。\n"
        "4. 篇幅控制在 600 字以内，不要重复罗列 JSON 全部字段，挑有解释力的写。"
    )
    resp = client.chat.completions.create(
        model=MODEL,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": json.dumps(ev, ensure_ascii=False, indent=2)},
        ],
        temperature=0.2,
    )
    return resp.choices[0].message.content or "", MODEL


# ---------------------------------------------------------------- 3. 事实校验 ----
def verify(text: str, ev: dict) -> tuple[list[tuple[str, bool]], float]:
    """把文本里的数字与证据比对。

    判定规则：文本中出现的每个数字（金额/百分比/整数），只要能在证据中找到
    「相近的值」（相对误差 <= 2%），就算有据；否则计为无据。
    阈值放 2% 是因为模型会把 0.3473 写成 34.7%，四舍五入会造成 1‰ 级偏差。
    """
    numeric_pool = []

    def walk(v):
        if isinstance(v, dict):
            for vv in v.values():
                walk(vv)
        elif isinstance(v, (list, tuple)):
            for vv in v:
                walk(vv)
        elif isinstance(v, (int, float)):
            numeric_pool.append(float(v))
        elif isinstance(v, str):
            for m in re.findall(r"\d+(?:\.\d+)?", v):
                numeric_pool.append(float(m))

    walk(ev)
    # 用绝对值建池：报告里写「跌幅 50.99%」而证据存 -0.5099，符号不该判为无据
    pool = np.abs(np.array([p for p in numeric_pool if p != 0], dtype=float))

    # 从文本里取数字。先去掉行首的列表序号（"1. " / "2、"），
    # 否则序号会被当成事实断言，把一致率算歪。
    body = re.sub(r"(?m)^\s*\d+[.、)]\s+", "", text)
    tokens = re.findall(r"\d[\d,]*(?:\.\d+)?%?", body)
    checked = []
    for tok in tokens:
        is_pct = tok.endswith("%")
        raw = tok.rstrip("%").replace(",", "")
        try:
            val = float(raw)
        except ValueError:
            continue
        if val in (2024.0, 2025.0, 1.0, 0.0) and not is_pct:
            continue
        cands = [val, val / 100 if is_pct else val * 100]
        ok = False
        for c in cands:
            if c == 0:
                continue
            hit = np.abs(pool - c) / max(abs(c), 1e-9) <= 0.02
            if hit.any():
                ok = True
                break
        checked.append((tok, ok))

    if not checked:
        return [], 0.0
    rate = sum(1 for _, ok in checked if ok) / len(checked)
    return checked, rate


def main() -> int:
    ev, daily, monthly = build_evidence()
    (OUTPUT_DIR / "insight_evidence.json").write_text(
        json.dumps(ev, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    if KEY:
        try:
            body, model_used = llm_report(ev)
            mode = f"大模型（{model_used}）"
        except Exception as e:
            body, mode = rule_report(ev), f"规则模板（LLM 调用失败：{type(e).__name__}）"
    else:
        body, mode = rule_report(ev), "规则模板（未配置 LLM_API_KEY）"

    checked, rate = verify(body, ev)
    no_evidence = [t for t, ok in checked if not ok]
    claim_cnt = len(checked)

    header = (
        f"# AI 智能洞察报告\n\n"
        f"> 生成时间：{datetime.now():%Y-%m-%d %H:%M}　|　生成方式：{mode}\n"
        f"> 事实校验：共 {claim_cnt} 处数字，有据 {claim_cnt - len(no_evidence)} 处，"
        f"一致率 **{rate:.1%}**\n\n"
    )
    footer = (
        "\n\n---\n\n### 事实校验明细\n\n"
        f"- 数字断言总数：{claim_cnt}\n"
        f"- 有据：{claim_cnt - len(no_evidence)}\n"
        f"- 无据：{len(no_evidence)}" + (f"（{'、'.join(no_evidence[:10])}）" if no_evidence else "") + "\n"
        f"- 一致率：{rate:.1%}\n\n"
        "> 校验方法：把报告中每个数字与证据 JSON（evidence）逐一比对，"
        "相对误差 ≤2% 记为有据（容差用于吸收百分比与小数互写造成的舍入差）。\n"
        "> 未通过的数字不等于结论错误，但必须回到原始数据复核后才能对外使用。\n"
    )

    out = OUTPUT_DIR / "ai_insight_report.md"
    out.write_text(header + body.strip() + footer, encoding="utf-8")

    print(f"生成方式: {mode}")
    print(f"数字断言: {claim_cnt} 处，一致率 {rate:.1%}")
    if no_evidence:
        print(f"无据数字: {no_evidence[:10]}")
    print(f"报告: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
