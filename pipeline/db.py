"""数据库连接和执行 SQL 脚本。

连接本机 SQL Server（Windows 身份验证）。服务器、数据库名可以用环境变量覆盖：
    MSSQL_SERVER（默认 localhost）、MSSQL_DATABASE（默认 MavenFuzzyFactory）、MSSQL_DRIVER
"""
from __future__ import annotations

import os
import re
from pathlib import Path

import pandas as pd
import pyodbc

ROOT = Path(__file__).resolve().parent.parent
SQL_DIR = ROOT / "sql"
DATABASE = os.getenv("MSSQL_DATABASE", "MavenFuzzyFactory")


def _driver() -> str:
    if os.getenv("MSSQL_DRIVER"):
        return os.environ["MSSQL_DRIVER"]
    names = pyodbc.drivers()
    for d in ("ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server",
              "SQL Server Native Client 11.0", "SQL Server Native Client 10.0", "SQL Server"):
        if d in names:
            return d
    raise RuntimeError(f"没有找到 SQL Server 的 ODBC 驱动，已安装：{names}")


def connect(database: str | None = DATABASE, autocommit: bool = True) -> pyodbc.Connection:
    server = os.getenv("MSSQL_SERVER", "localhost")
    db = f"DATABASE={database};" if database else ""
    extra = "TrustServerCertificate=yes;" if "ODBC Driver 18" in _driver() else ""
    return pyodbc.connect(f"DRIVER={{{_driver()}}};SERVER={server};{db}Trusted_Connection=yes;{extra}",
                          autocommit=autocommit, timeout=10)


def split_batches(sql: str) -> list[str]:
    """按单独一行的 GO 拆成批次（GO 是 SSMS 的批次分隔符，不是 SQL 语句）。"""
    parts = re.split(r"^\s*GO\s*$", sql, flags=re.IGNORECASE | re.MULTILINE)
    return [p.strip() for p in parts if p.strip()]


def run_sql_file(path: Path, conn: pyodbc.Connection, params: dict[str, str] | None = None) -> None:
    """执行一个 .sql 文件。params 用来替换文件里的 {{名字}} 占位符（如数据文件夹路径）。"""
    sql = path.read_text(encoding="utf-8")
    for k, v in (params or {}).items():
        sql = sql.replace("{{" + k + "}}", v)
    cur = conn.cursor()
    for batch in split_batches(sql):
        cur.execute(batch)
        while cur.nextset():           # 把多结果集读完，否则下一批会报“连接忙”
            pass


def query(sql: str, conn: pyodbc.Connection | None = None, params: list | None = None) -> pd.DataFrame:
    own = conn is None
    conn = conn or connect()
    try:
        cur = conn.cursor()
        cur.execute(sql, params or [])
        cols = [c[0] for c in cur.description]
        return pd.DataFrame.from_records([tuple(r) for r in cur.fetchall()], columns=cols)
    finally:
        if own:
            conn.close()
