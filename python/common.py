"""公共工具：Hive 连接、环境变量、路径。

放在 python/ 下，供 01~06 各脚本 import，避免每个脚本重复写连接串。
"""
from __future__ import annotations

import os
from pathlib import Path

# ---------------------------------------------------------------- 路径 ----
BASE_DIR = Path(__file__).resolve().parent.parent
OUTPUT_DIR = BASE_DIR / "output"
OUTPUT_DIR.mkdir(exist_ok=True)

DOCS_IMG_DIR = BASE_DIR / "docs" / "images"
DOCS_IMG_DIR.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------- 环境变量 ----
def load_env(path: Path | None = None) -> None:
    """加载 .env，不覆盖已存在的真实环境变量。

    为什么不用 os.environ.setdefault 一把梭：CI 里通常用真实环境变量注入密钥，
    若 .env 里的占位值把它覆盖掉，会出现「本地能跑、线上 401」的诡异问题。
    """
    try:
        from dotenv import load_dotenv
    except ImportError:  # 依赖未装时退化为手工解析
        path = path or (BASE_DIR / ".env")
        if path.exists():
            for line in path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
        return
    load_dotenv(path or (BASE_DIR / ".env"), override=False)


# ---------------------------------------------------------------- Hive ----
HIVE_HOST = os.environ.get("HIVE_HOST", "localhost")
HIVE_PORT = int(os.environ.get("HIVE_PORT", "10000"))
HIVE_DB = os.environ.get("HIVE_DB", "ydsh_ads")


def get_hive_conn(database: str | None = None):
    """返回 pyhive 连接。

    注意 port 必须走容器映射到宿主机的 10000，
    host 用 localhost 而不是容器名——脚本在宿主机跑，不在 Docker 网络里。
    """
    from pyhive import hive

    return hive.Connection(host=HIVE_HOST, port=HIVE_PORT, database=database or HIVE_DB)


def query_df(sql: str, database: str | None = None):
    """执行 SQL 返回 DataFrame。

    pandas 2.x 对 DBAPI 连接会告警（只承诺支持 SQLAlchemy），但对 pyhive 实际可用；
    这里显式吞掉该告警，避免日志噪音盖住真正的错误。
    """
    import warnings

    import pandas as pd

    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        conn = get_hive_conn(database)
        try:
            df = pd.read_sql(sql, conn)
        finally:
            conn.close()

    # pyhive 在 SELECT * 时返回带表名前缀的列名（ads_kpi_overview.gmv），
    # 下游按 df["gmv"] 取会 KeyError，这里统一去掉前缀。
    df.columns = [c.split(".")[-1] if "." in c else c for c in df.columns]
    return df


def save_fig(fig, name: str) -> Path:
    """保存图片到 docs/images/，返回路径。"""
    out = DOCS_IMG_DIR / name
    fig.savefig(out, dpi=140, bbox_inches="tight", facecolor="white")
    return out
