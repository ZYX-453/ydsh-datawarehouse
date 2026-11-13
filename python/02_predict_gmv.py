"""02 — 日 GMV 时间序列分析与 7 天预测建模。

流程：
    1. 读 output/daily_gmv.csv（由 01 从 ADS 抽取）
    2. 描述性分析：趋势（7/30 日移动平均）、周内效应、月度环比
    3. 特征工程：lag1~lag7、ma7、ma14、weekday、day_of_month
    4. 建模：常数均值基线 / 朴素基线(lag7) / 线性回归 / 随机森林 / 梯度提升
       —— 基线是及格线：任何模型打不过「直接输出均值」，就说明它只学到了噪声
       —— 评估用「按时间切分」的末 7 天留出集，绝不用随机切分（会造成未来信息泄漏）
    5. 回测指标：MAE / MAPE / RMSE / R²
    6. 用全量数据重训后，递归预测 2025-01-01 ~ 01-07
输出：
    output/model_metrics.csv        各模型回测指标
    output/forecast_next7.csv       未来 7 天预测
    docs/images/fig_01_daily_trend.png
    docs/images/fig_02_weekday_effect.png
    docs/images/fig_03_backtest.png
    docs/images/fig_04_forecast.png
用法：
    python 02_predict_gmv.py
"""
from __future__ import annotations

import warnings

import numpy as np
import pandas as pd

from common import OUTPUT_DIR, save_fig

warnings.filterwarnings("ignore")

import matplotlib  # noqa: E402

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

from sklearn.ensemble import GradientBoostingRegressor, RandomForestRegressor  # noqa: E402
from sklearn.linear_model import LinearRegression  # noqa: E402
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score  # noqa: E402

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

HOLDOUT_DAYS = 7
TARGET = "gmv"


# ---------------------------------------------------------------- 特征 ----
def build_features(df: pd.DataFrame) -> pd.DataFrame:
    """构造滞后与日历特征。

    只用「当天及以前」的信息，避免前视泄漏：
    lag_k = 前 k 天的 GMV，ma7/ma14 = 截至昨天的移动平均（shift(1) 后再 rolling）。
    """
    out = df.copy()
    for k in range(1, 8):
        out[f"lag{k}"] = out[TARGET].shift(k)
    # 关键：先 shift 再 rolling，否则当天的 GMV 会进入当天的 ma7，等于作弊
    out["ma7"] = out[TARGET].shift(1).rolling(7).mean()
    out["ma14"] = out[TARGET].shift(1).rolling(14).mean()
    out["weekday"] = out["stat_date"].dt.dayofweek + 1        # 1=周一
    out["day_of_month"] = out["stat_date"].dt.day
    out["is_weekend"] = (out["stat_date"].dt.dayofweek >= 5).astype(int)
    return out


FEATURES = [f"lag{k}" for k in range(1, 8)] + ["ma7", "ma14", "weekday", "day_of_month", "is_weekend"]


def metrics(y_true, y_pred) -> dict:
    y_true = np.asarray(y_true, dtype=float)
    y_pred = np.asarray(y_pred, dtype=float)
    mape = float(np.mean(np.abs((y_true - y_pred) / y_true)) * 100)
    return {
        "MAE": float(mean_absolute_error(y_true, y_pred)),
        "RMSE": float(np.sqrt(mean_squared_error(y_true, y_pred))),
        "MAPE(%)": mape,
        "R2": float(r2_score(y_true, y_pred)),
    }


# ---------------------------------------------------------------- 主流程 ----
def main() -> int:
    src = OUTPUT_DIR / "daily_gmv.csv"
    df = pd.read_csv(src, parse_dates=["stat_date"]).sort_values("stat_date").reset_index(drop=True)
    print(f"读入 {len(df)} 天：{df['stat_date'].min():%Y-%m-%d} ~ {df['stat_date'].max():%Y-%m-%d}")

    # ---------------- 1. 描述性分析 ----------------
    df["ma7"] = df[TARGET].rolling(7).mean()
    df["ma30"] = df[TARGET].rolling(30).mean()

    x = np.arange(len(df))
    slope, intercept = np.polyfit(x, df[TARGET].values, 1)
    trend_pct_per_month = slope * 30 / df[TARGET].mean() * 100
    weekday_mean = df.groupby(df["stat_date"].dt.dayofweek + 1)[TARGET].agg(["mean", "count"])
    wd_names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    print("\n=== 趋势 ===")
    print(f"日均 GMV      : {df[TARGET].mean():,.2f}")
    print(f"线性趋势斜率  : {slope:,.2f} 元/天（折合 {trend_pct_per_month:+.2f}% / 月）")
    print(f"最高 / 最低日 : {df[TARGET].max():,.2f} ({df.loc[df[TARGET].idxmax(),'stat_date']:%m-%d})"
          f" / {df[TARGET].min():,.2f} ({df.loc[df[TARGET].idxmin(),'stat_date']:%m-%d})")
    print(f"日 GMV 变异系数: {df[TARGET].std() / df[TARGET].mean():.3f}")
    print("\n=== 周内效应（日均 GMV）===")
    for i, row in weekday_mean.iterrows():
        print(f"  {wd_names[i-1]}: {row['mean']:>10,.2f}  (n={int(row['count'])})")
    wd_ratio = weekday_mean["mean"].max() / weekday_mean["mean"].min()
    print(f"  最强 / 最弱 = {wd_ratio:.3f} 倍")
    if wd_ratio < 1.05:
        print("  → 周内差异不足 5%，说明该数据集没有可学习的周内季节性")

    # 月度环比（来自 ADS，已是 SQL 侧算好的口径）
    monthly = pd.read_csv(OUTPUT_DIR / "monthly_kpi.csv")
    print("\n=== 月度 GMV 与环比 ===")
    print(monthly[["stat_ym", "gmv", "order_cnt", "aov", "gmv_mom"]].to_string(index=False,
          formatters={"gmv": "{:,.2f}".format, "aov": "{:,.2f}".format, "gmv_mom": "{:+.2%}".format}))

    # ---------------- 2. 特征与切分 ----------------
    feat = build_features(df).dropna().reset_index(drop=True)
    print(f"\n特征后样本数: {len(feat)}（因 lag14 丢弃前 14 天）")

    train = feat.iloc[:-HOLDOUT_DAYS]
    test = feat.iloc[-HOLDOUT_DAYS:]
    X_tr, y_tr = train[FEATURES], train[TARGET]
    X_te, y_te = test[FEATURES], test[TARGET]

    models = {
        "常数均值基线": None,      # 用训练集均值预测，任何模型的及格线
        "朴素基线(lag7)": None,
        "线性回归": LinearRegression(),
        "随机森林": RandomForestRegressor(n_estimators=300, max_depth=6, min_samples_leaf=3, random_state=42),
        "梯度提升": GradientBoostingRegressor(n_estimators=200, max_depth=3, learning_rate=0.05, random_state=42),
    }

    rows, preds = [], {}
    for name, model in models.items():
        if name == "常数均值基线":
            # 及格线：不做任何学习，直接输出训练集均值。
            # 模型若打不过它，说明学到的全是噪声（R² 也会是负数）。
            p = np.full(len(y_te), float(y_tr.mean()))
        elif model is None:
            p = test["lag7"].values
        else:
            model.fit(X_tr, y_tr)
            p = model.predict(X_te)
        preds[name] = p
        rows.append({"model": name, **metrics(y_te, p)})

    result = pd.DataFrame(rows)
    print("\n=== 末 7 天回测（按时间切分，无泄漏）===")
    print(result.to_string(index=False, formatters={
        "MAE": "{:,.2f}".format, "RMSE": "{:,.2f}".format, "MAPE(%)": "{:.2f}".format, "R2": "{:.4f}".format}))

    result.to_csv(OUTPUT_DIR / "model_metrics.csv", index=False, encoding="utf-8-sig")

    # 基线（常数均值 / lag7）不参与「最优可学习模型」评选，只作为及格线
    learnable = result[~result["model"].isin(["常数均值基线", "朴素基线(lag7)"])]
    best = learnable.loc[learnable["MAPE(%)"].idxmin(), "model"]
    base_mape = float(result.loc[result["model"] == "常数均值基线", "MAPE(%)"].iloc[0])
    best_mape = float(learnable["MAPE(%)"].min())
    print(f"\n最优可学习模型（按 MAPE）: {best}（{best_mape:.2f}%）")
    if best_mape >= base_mape:
        print(f"[WARN] 未战胜常数均值基线（{base_mape:.2f}%）：模型学到的增量信息 ≈ 0，"
              f"预测结果只能当参考区间，不具备业务决策价值")
    else:
        print(f"      较常数均值基线（{base_mape:.2f}%）降低 {base_mape - best_mape:.2f} 个百分点")

    # ---------------- 3. 递归预测未来 7 天 ----------------
    # 选中的模型在全量数据上重训；预测第 t+1 天时，把预测值回填成新的 lag1，
    # 这是标准的递归多步预测，误差会累积，报告中必须写明。
    best_model = models[best]
    if best_model is None:
        print("[WARN] 最优为朴素基线，不做递归预测，直接用 lag7 平移")
        last_week = df[TARGET].iloc[-7:].values
        fc_values = list(last_week)
    else:
        best_model.fit(feat[FEATURES], feat[TARGET])
        history = df[TARGET].tolist()
        dates = df["stat_date"].tolist()
        fc_values = []
        for step in range(1, HOLDOUT_DAYS + 1):
            next_date = dates[-1] + pd.Timedelta(days=step)
            row = {}
            for k in range(1, 8):
                row[f"lag{k}"] = history[-k]
            row["ma7"] = float(np.mean(history[-7:]))
            row["ma14"] = float(np.mean(history[-14:]))
            row["weekday"] = next_date.dayofweek + 1
            row["day_of_month"] = next_date.day
            row["is_weekend"] = int(next_date.dayofweek >= 5)
            yhat = float(best_model.predict(pd.DataFrame([row])[FEATURES])[0])
            fc_values.append(yhat)
            history.append(yhat)

    fc_dates = pd.date_range(df["stat_date"].max() + pd.Timedelta(days=1), periods=HOLDOUT_DAYS)
    forecast = pd.DataFrame({"stat_date": fc_dates, "pred_gmv": fc_values})
    forecast["pred_gmv"] = forecast["pred_gmv"].round(2)
    forecast.to_csv(OUTPUT_DIR / "forecast_next7.csv", index=False, encoding="utf-8-sig")
    print("\n=== 未来 7 天 GMV 预测 ===")
    print(forecast.to_string(index=False, formatters={"pred_gmv": "{:,.2f}".format}))
    print(f"7 天合计: {forecast['pred_gmv'].sum():,.2f}")

    # ---------------- 4. 绘图 ----------------
    # 图 1：日序列 + 7/30 日移动平均 + 趋势线
    fig, ax = plt.subplots(figsize=(11, 4.2))
    ax.plot(df["stat_date"], df[TARGET], lw=0.8, color="#9aa7b8", label="日 GMV")
    ax.plot(df["stat_date"], df["ma7"], lw=1.6, color="#2f6fb5", label="7 日移动平均")
    ax.plot(df["stat_date"], df["ma30"], lw=1.6, color="#d9822b", label="30 日移动平均")
    ax.plot(df["stat_date"], intercept + slope * x, lw=1.4, ls="--", color="#c0392b", label="线性趋势")
    ax.set_title("2024 年日 GMV、移动平均与线性趋势")
    ax.set_ylabel("GMV（元）")
    ax.legend(loc="upper left", ncol=4, fontsize=8)
    ax.grid(alpha=0.25)
    fig.autofmt_xdate()
    print(f"\n图 1 已保存: {save_fig(fig, 'fig_01_daily_trend.png')}")
    plt.close(fig)

    # 图 2：周内效应
    fig, ax = plt.subplots(figsize=(7, 3.6))
    bars = ax.bar([wd_names[i - 1] for i in weekday_mean.index], weekday_mean["mean"], color="#4a7ebb")
    ax.axhline(df[TARGET].mean(), ls="--", lw=1, color="#c0392b", label="日均水平")
    for b, v in zip(bars, weekday_mean["mean"]):
        ax.text(b.get_x() + b.get_width() / 2, v, f"{v:,.0f}", ha="center", va="bottom", fontsize=7)
    ax.set_title("周内日均 GMV")
    ax.set_ylabel("GMV（元）")
    ax.legend()
    ax.grid(axis="y", alpha=0.25)
    print(f"图 2 已保存: {save_fig(fig, 'fig_02_weekday_effect.png')}")
    plt.close(fig)

    # 图 3：回测对比
    fig, ax = plt.subplots(figsize=(7.5, 3.8))
    ax.plot(test["stat_date"], y_te, "o-", lw=1.8, label="真实值", color="#1f2d3d")
    for name in ["朴素基线(lag7)", "梯度提升", "线性回归"]:
        ax.plot(test["stat_date"], preds[name], "s--", lw=1.3, label=f"{name}预测")
    ax.set_title("末 7 天回测：预测 vs 真实")
    ax.set_ylabel("GMV（元）")
    ax.legend(fontsize=8)
    ax.grid(alpha=0.25)
    fig.autofmt_xdate()
    print(f"图 3 已保存: {save_fig(fig, 'fig_03_backtest.png')}")
    plt.close(fig)

    # 图 4：未来 7 天预测
    fig, ax = plt.subplots(figsize=(9, 3.8))
    tail = df.tail(30)
    ax.plot(tail["stat_date"], tail[TARGET], lw=1.4, color="#1f2d3d", label="近 30 天真实值")
    ax.plot(forecast["stat_date"], forecast["pred_gmv"], "o--", lw=1.6, color="#c0392b",
            label=f"未来 7 天预测（{best}）")
    ax.set_title("未来 7 天 GMV 预测（递归多步）")
    ax.set_ylabel("GMV（元）")
    ax.legend(fontsize=8)
    ax.grid(alpha=0.25)
    fig.autofmt_xdate()
    print(f"图 4 已保存: {save_fig(fig, 'fig_04_forecast.png')}")
    plt.close(fig)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
