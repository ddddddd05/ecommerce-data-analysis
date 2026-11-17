"""经营看板后端（FastAPI）：只读应用层（ads）的表，给前端页面提供 JSON。

    uvicorn dashboard.app:app --port 8100     → 打开 http://localhost:8100

数据来源优先读 SQL Server 的应用层；数据库连不上时，退回读流水线导出的 outputs/*.csv，
这样没装 SQL Server 的电脑也能打开看板。接口只开放白名单里的表，不接受任意 SQL。
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import pandas as pd
from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline.db import ROOT, query  # noqa: E402
from pipeline.run_pipeline import EXPORT_TABLES  # noqa: E402

STATIC = Path(__file__).resolve().parent / "static"
OUTPUTS = ROOT / "outputs"


def load_table(name: str, source: str = "auto") -> tuple[pd.DataFrame, str]:
    if name not in EXPORT_TABLES:
        raise HTTPException(404, f"没有这张表：{name}")
    if source in ("auto", "db"):
        try:
            return query(f"SELECT * FROM ads.{name}"), "SQL Server"
        except Exception:  # noqa: BLE001
            if source == "db":
                raise
    csv = OUTPUTS / f"{name}.csv"
    if not csv.exists():
        raise HTTPException(503, "数据库连不上，也没有导出文件，请先运行 python pipeline/run_pipeline.py")
    return pd.read_csv(csv), "CSV 导出文件"


def to_records(df: pd.DataFrame) -> list[dict]:
    """DataFrame → JSON：日期转字符串、Decimal 转 float、NaN 转 null。"""
    out = []
    for row in df.to_dict("records"):
        clean = {}
        for k, v in row.items():
            if isinstance(v, pd.Timestamp):
                v = v.strftime("%Y-%m-%d")
            elif hasattr(v, "is_finite"):                       # decimal.Decimal
                v = float(v)
            elif hasattr(v, "item"):                            # numpy 类型
                v = v.item()
            if isinstance(v, float) and math.isnan(v):
                v = None
            if isinstance(v, str) and len(v) >= 10 and v[4] == "-" and " 00:00:00" in v:
                v = v[:10]
            clean[k] = v
        out.append(clean)
    return out


def create_app(source: str = "auto") -> FastAPI:
    app = FastAPI(title="Maven Fuzzy Factory 经营看板")

    @app.get("/api/tables")
    def tables():
        return EXPORT_TABLES

    @app.get("/api/tables/{name}")
    def table(name: str):
        df, src = load_table(name, source)
        return {"table": name, "source": src, "rows": to_records(df)}

    app.mount("/", StaticFiles(directory=STATIC, html=True), name="static")
    return app


app = create_app()
