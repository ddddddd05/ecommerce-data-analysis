"""把原始 CSV 转成 SQL Server 2008 的 BULK INSERT 能直接读的格式（只改文件格式，不改任何值）。

为什么需要这一步：SQL Server 2008 的 BULK INSERT 不认识 CSV 的双引号（2017 才支持 FORMAT='CSV'），
website_pageviews.csv 的时间字段带引号（"2012-03-19 08:04:16"），直接导入会把引号也存进去。
这里用 Python 的 csv 模块正确解析引号，再写成制表符分隔的文件。

检查：每个文件转换前后的行数、列数必须一致，任何一行列数不对就报错停止，不会悄悄丢数据。
"""
from __future__ import annotations

import csv
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
STAGING = ROOT / "data" / "staging"

TABLES = ["website_sessions", "website_pageviews", "orders", "order_items",
          "order_item_refunds", "products"]


def convert(table: str, raw: Path = RAW, staging: Path = STAGING) -> dict:
    src, dst = raw / f"{table}.csv", staging / f"{table}.tsv"
    staging.mkdir(parents=True, exist_ok=True)
    rows = 0
    with open(src, newline="", encoding="utf-8-sig") as fin, \
            open(dst, "w", newline="", encoding="ascii") as fout:
        reader = csv.reader(fin)
        header = next(reader)
        fout.write("\t".join(header) + "\n")
        for line_no, row in enumerate(reader, start=2):
            if len(row) != len(header):
                raise ValueError(f"{src.name} 第 {line_no} 行有 {len(row)} 列，表头是 {len(header)} 列")
            if any("\t" in v or "\n" in v for v in row):
                raise ValueError(f"{src.name} 第 {line_no} 行含制表符或换行，不能用制表符分隔")
            fout.write("\t".join(row) + "\n")
            rows += 1
    return {"table": table, "columns": header, "rows": rows}


def main() -> list[dict]:
    result = [convert(t) for t in TABLES]
    (STAGING / "manifest.json").write_text(json.dumps(result, ensure_ascii=False, indent=2),
                                           encoding="utf-8")
    for r in result:
        print(f"{r['table']:<20} {r['rows']:>9} 行")
    return result


if __name__ == "__main__":
    main()
