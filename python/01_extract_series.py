"""01 — 从 Hive 抽取时间序列，落到本地 CSV。

数据源：ydsh_ads.ads_sales_daily（日 GMV / 订单 / 用户 / AOV / MA7）
输出：
    output/daily_gmv.csv          日序列（预测建模输入）
    output/monthly_kpi.csv        月度 KPI（趋势与环比）
用法：
    python 01_extract_series.py
"""
from __future__ import annotations

import sys

import pandas as pd

from common import OUTPUT_DIR, query_df

DAILY_SQL = """
SELECT stat_date, gmv, order_cnt, user_cnt, aov, ma7, weekday
FROM ads_sales_daily
ORDER BY stat_date
"""

MONTHLY_SQL = """
SELECT stat_ym, gmv, order_cnt, aov, user_cnt, repurchase_rate, gmv_mom, order_mom
FROM ads_kpi_month
ORDER BY stat_ym
"""


def main() -> int:
    daily = query_df(DAILY_SQL, "ydsh_ads")
    monthly = query_df(MONTHLY_SQL, "ydsh_ads")

    if daily.empty:
        print("[ERROR] ads_sales_daily 为空，先跑 sql/ads 下的加载脚本", file=sys.stderr)
        return 1

    daily["stat_date"] = pd.to_datetime(daily["stat_date"])
    daily = daily.sort_values("stat_date").reset_index(drop=True)

    daily_path = OUTPUT_DIR / "daily_gmv.csv"
    monthly_path = OUTPUT_DIR / "monthly_kpi.csv"
    daily.to_csv(daily_path, index=False, encoding="utf-8-sig")
    monthly.to_csv(monthly_path, index=False, encoding="utf-8-sig")

    print(f"日序列  : {len(daily)} 行  {daily['stat_date'].min():%Y-%m-%d} ~ {daily['stat_date'].max():%Y-%m-%d}")
    print(f"GMV 合计: {daily['gmv'].sum():,.2f}")
    print(f"订单合计: {int(daily['order_cnt'].sum()):,}")
    print(f"输出    : {daily_path}")
    print(f"输出    : {monthly_path} ({len(monthly)} 行)")

    # 数据质量快检：日序列不该有缺口
    gap = pd.date_range(daily["stat_date"].min(), daily["stat_date"].max()).difference(daily["stat_date"])
    print(f"日期缺口: {len(gap)} 天" + (f" -> {list(gap[:5])}" if len(gap) else ""))
    print(f"缺失值  :\n{daily.isna().sum().to_string()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
