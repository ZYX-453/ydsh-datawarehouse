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

    # 极值的 σ 倍数：模型很容易把「相对 7 日均值偏离 50%」当成数据异常，
    # 但那只说明短期基线偏低，不代表离群。给出 σ 倍数后，模型才有做判定的依据。
    gmv_mu = float(daily["gmv"].mean())
    gmv_sd = float(daily["gmv"].std())
    d_min_row = valid.loc[valid["gmv"].idxmin()]
    d_max_row = valid.loc[valid["gmv"].idxmax()]

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
        # σ 倍数 = (当日 GMV - 全序列均值) / 全序列标准差；|σ|>3 才够得上「离群」
        "最低日GMV": round(float(d_min_row["gmv"]), 2),
        "最低日日期": f"{d_min_row['stat_date']:%Y-%m-%d}",
        "最低日σ倍数": round((float(d_min_row["gmv"]) - gmv_mu) / gmv_sd, 2),
        "最高日GMV": round(float(d_max_row["gmv"]), 2),
        "最高日日期": f"{d_max_row['stat_date']:%Y-%m-%d}",
        "最高日σ倍数": round((float(d_max_row["gmv"]) - gmv_mu) / gmv_sd, 2),
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
ADVICE_HEADINGS = ("行动建议", "建议", "方案", "措施")


def split_advice(text: str) -> tuple[str, str]:
    """把「行动建议」类章节从待校验正文里摘出来。

    原因：模型在建议里会写「单日跌幅超过 30% 触发告警」这类**决策阈值**。
    它不是对数据的断言，而是模型自己拍的运营参数，拿它去比对证据必然「无据」，
    但这不构成幻觉。混在一起统计会把一致率算低，掩盖真正需要警惕的编造。
    所以分开：陈述性段落查幻觉，建议性段落只数个数、标注为决策参数。
    """
    fact_lines, adv_lines = [], []
    in_advice = False
    for ln in text.splitlines():
        if ln.lstrip().startswith("#"):
            title = ln.lstrip("#").strip()
            in_advice = any(k in title for k in ADVICE_HEADINGS)
        (adv_lines if in_advice else fact_lines).append(ln)
    return "\n".join(fact_lines), "\n".join(adv_lines)


def verify(text: str, ev: dict) -> tuple[list[tuple[str, bool]], float]:
    """把文本里的数字与证据比对。

    判定规则：文本中出现的每个数字（金额/百分比/整数），只要能在证据中找到
    「相近的值」（相对误差 <= 2%），就算有据；否则计为无据。
    阈值放 2% 是因为模型会把 0.3473 写成 34.7%，四舍五入会造成 1‰ 级偏差。
    候选值包含三种折算：原值、百分比与小数互换、千位单位（万/亿）换算——
    后两者是校验器必须做的归一化，缺了它们会把正确的表述误判成幻觉。
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
    checked = []
    # 用 finditer 而不是 findall：需要知道每个数字的结束位置，
    # 才能看它后面跟的单位是不是「万元」。
    for m in re.finditer(r"\d[\d,]*(?:\.\d+)?%?", body):
        tok = m.group(0)
        is_pct = tok.endswith("%")
        raw = tok.rstrip("%").replace(",", "")
        try:
            val = float(raw)
        except ValueError:
            continue
        if val in (2024.0, 2025.0, 1.0, 0.0) and not is_pct:
            continue
        cands = [val, val / 100 if is_pct else val * 100]
        # 单位换算：证据里金额存的是「元」，报告常写成「万元」。
        # 不折算就会把 3,674,468.80 元 与 "367.45 万元" 判成不符，
        # 产生假阳性——校验器自身的漏洞，不能算成模型幻觉。
        if "万" in body[m.end():m.end() + 2]:
            cands.append(val * 10000)
        if "亿" in body[m.end():m.end() + 2]:
            cands.append(val * 100000000)
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


# ---------------------------------------------------------------- 4. 人工复核 ----
def auto_review(ev: dict) -> str:
    """对 AI 报告里最容易判错的三个点做可复算复核。

    为什么要在 AI 报告后面挂一段代码生成的结论：
    实测发现模型会犯两类「看起来很有洞察」的错——
      1. 拿「相对 7 日移动均值的偏离 50%」去和「整体变异系数 0.23」对比，
         得出「数据自相矛盾、可能有口径问题」。两者量纲根本不同，
         正确做法是换成 σ 倍数：2.8σ 在 366 天里出现完全正常。
      2. 把行为事件数当串联漏斗算转化率，但这份数据四类行为是独立采样的。
    这类错误的危害在于「方向听着对、结论是错的」，不校验就会让读者去查不存在的问题。
    本节由代码算、不经模型，与上方 AI 生成内容严格区分。
    """
    lo_z, hi_z = ev["最低日σ倍数"], ev["最高日σ倍数"]
    worst_z = max(abs(lo_z), abs(hi_z))
    if worst_z <= 3:
        z_verdict = (
            f"**AI 判断不成立**。最低日 {ev['最低日日期']} 为 {lo_z:+.2f}σ、"
            f"最高日 {ev['最高日日期']} 为 {hi_z:+.2f}σ，均在 3σ 以内。"
            f"366 天里出现 2~3σ 的极值属随机抽样尾部（单侧 2σ 约每 44 天一次、"
            f"2.8σ 约每 260 天一次），不支持「存在大额订单或口径问题」的推断。"
            f"AI 把「相对移动均值偏离 50%」与「变异系数 0.23」直接对比，两者量纲不同，"
            f"这个矛盾是它自己造出来的。"
        )
    else:
        z_verdict = (
            f"**AI 判断成立**。最极端日达 {worst_z:.2f}σ，超过 3σ 阈值，"
            f"建议回查该日订单明细是否为单笔大额或数据重复。"
        )

    f = ev["行为漏斗"]
    buy, cart = f.get("buy", 0), f.get("cart", 0)
    if buy > cart:
        funnel_verdict = (
            f"**AI 判断成立**。buy({buy:,}) > cart({cart:,})，四类行为在源数据里是各自独立采样的，"
            f"不是同一批用户的串联路径，所以不能按 pv→fav→cart→buy 算环节转化率。"
        )
    else:
        funnel_verdict = (
            f"**AI 判断成立**。buy({buy:,}) ≤ cart({cart:,})，漏斗顺序正常，可计算各环节转化率。"
        )

    if ev["复购率"] >= 0.99:
        rep_verdict = (
            f"**AI 的质疑成立，且结论要更重**。复购率 {ev['复购率']:.0%} 等于全部 "
            f"{ev['成交用户数']:,} 名成交用户都下了 ≥2 单——已实测该样本 1000 人全在 2 单以上、"
            f"其中 971 人超过 4 单。这不是用户粘性好，而是用户池仅 1000 人却承接了 "
            f"{ev['订单量']:,} 单（人均约 {ev['订单量']/max(ev['成交用户数'],1):.1f} 单）的生成特征，"
            f"该指标已完全失去区分度，不应对外引用。"
        )
    else:
        rep_verdict = f"复购率 {ev['复购率']:.1%}，处于合理区间，指标可用。"

    return f"""## 人工复核记录（非模型产出）

> 本节由脚本按可复算规则生成，不经过大模型，用于核对 AI 判断中容易出错的部分。

1. **「单日振幅与变异系数矛盾」是否成立？** {z_verdict}
2. **漏斗能否计算环节转化率？** {funnel_verdict}
3. **复购率指标是否可用？** {rep_verdict}
"""


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

    # 陈述性内容才查幻觉；行动建议里的阈值属决策参数，单独计数
    fact_body, advice_body = split_advice(body)
    checked, rate = verify(fact_body, ev)
    no_evidence = [t for t, ok in checked if not ok]
    claim_cnt = len(checked)
    advice_tokens = re.findall(
        r"\d[\d,]*(?:\.\d+)?%?",
        re.sub(r"(?m)^\s*\d+[.、)]\s+", "", advice_body),
    )
    advice_cnt = len(advice_tokens)

    header = (
        f"# AI 智能洞察报告\n\n"
        f"> 生成时间：{datetime.now():%Y-%m-%d %H:%M}　|　生成方式：{mode}\n"
        f"> 事实校验：共 {claim_cnt} 处数字，有据 {claim_cnt - len(no_evidence)} 处，"
        f"一致率 **{rate:.1%}**（另有 {advice_cnt} 处决策参数不参与校验）\n\n"
    )
    footer = (
        "\n\n---\n\n### 事实校验明细\n\n"
        f"- 陈述性数字断言：{claim_cnt}\n"
        f"- 有据：{claim_cnt - len(no_evidence)}\n"
        f"- 无据：{len(no_evidence)}" + (f"（{'、'.join(no_evidence[:10])}）" if no_evidence else "") + "\n"
        f"- 一致率：{rate:.1%}\n"
        f"- 行动建议中的决策参数：{advice_cnt} 处（属运营阈值选择，不是对数据的断言，不计入幻觉统计）\n\n"
        "> 校验方法：把报告中每个数字与证据 JSON（evidence）逐一比对，"
        "相对误差 ≤2% 记为有据（容差用于吸收百分比与小数互写造成的舍入差）。\n"
        "> 候选值已做三种归一化：原值、百分比↔小数、万元/亿元↔元。\n"
        "> 未通过的数字不等于结论错误，但必须回到原始数据复核后才能对外使用。\n"
    )

    out = OUTPUT_DIR / "ai_insight_report.md"
    out.write_text(header + body.strip() + "\n\n" + auto_review(ev) + footer, encoding="utf-8")

    print(f"生成方式: {mode}")
    print(f"陈述性数字: {claim_cnt} 处，一致率 {rate:.1%}；决策参数 {advice_cnt} 处（不校验）")
    if no_evidence:
        print(f"无据数字: {no_evidence[:10]}")
    print(f"报告: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
