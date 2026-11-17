"""一键运行整条数据流水线：原始 CSV → 原始层 → 质量检查 → 明细层 → 汇总层 → 应用层 → A/B 测试 → 导出。

    python pipeline/run_pipeline.py              # 全部重跑（约 1～2 分钟）
    python pipeline/run_pipeline.py --from 03    # 从明细层开始重跑（原始层没变时用）

每一步都可以重复运行（先删后建），结果相同。任何“阻断”级质量检查没通过，流水线立即停止，
不会用有问题的数据继续算指标。运行记录写在 outputs/pipeline.log。
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline import prepare_staging  # noqa: E402
from pipeline.db import DATABASE, ROOT, SQL_DIR, connect, query, run_sql_file  # noqa: E402

OUTPUTS = ROOT / "outputs"
log = logging.getLogger("pipeline")

# 导出给报告和看板用的应用层表
EXPORT_TABLES = ["kpi_monthly", "kpi_quarterly", "kpi_yearly", "channel_yearly", "channel_type_quarterly",
                 "paid_search_device", "funnel_device", "product_quarterly", "cross_sell", "refund_monthly",
                 "repeat_visitors", "traffic_heatmap", "ab_test_results"]


class QualityGateError(RuntimeError):
    """有“阻断”级质量问题。"""


def quality_gate(conn, stage: str) -> None:
    bad = query("SELECT table_name, check_name, failed_rows FROM dq.check_results "
                "WHERE severity = N'阻断' AND failed_rows > 0", conn)
    if len(bad):
        for r in bad.itertuples():
            log.error("质量检查未通过 [%s] %s：%s 行", r.table_name, r.check_name, r.failed_rows)
        raise QualityGateError(f"{stage}之后有 {len(bad)} 项阻断级质量问题，流水线停止")
    log.info("质量关卡通过（%s）", stage)


def record_load(conn, manifest: list[dict]) -> None:
    """导入后核对：每张表实际导入的行数必须等于文件行数。"""
    cur = conn.cursor()
    for m in manifest:
        loaded = cur.execute(f"SELECT COUNT(*) FROM ods.{m['table']}").fetchone()[0]
        cur.execute("INSERT dq.load_log (table_name, file_rows, loaded_rows) VALUES (?, ?, ?)",
                    m["table"], m["rows"], loaded)
        if loaded != m["rows"]:
            raise QualityGateError(f"ods.{m['table']} 导入 {loaded} 行，文件有 {m['rows']} 行")
        log.info("ods.%-20s %9d 行（与文件一致）", m["table"], loaded)


def export(conn) -> None:
    OUTPUTS.mkdir(exist_ok=True)
    for t in EXPORT_TABLES:
        query(f"SELECT * FROM ads.{t}", conn).to_csv(OUTPUTS / f"{t}.csv", index=False, encoding="utf-8-sig")
    query("SELECT category, table_name, check_name, severity, failed_rows FROM dq.check_results ORDER BY check_id",
          conn).to_csv(OUTPUTS / "quality_checks.csv", index=False, encoding="utf-8-sig")
    log.info("已导出 %d 张应用层表和质量检查结果到 outputs/", len(EXPORT_TABLES))


def main(start_from: str = "00") -> None:
    OUTPUTS.mkdir(exist_ok=True)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                        handlers=[logging.StreamHandler(),
                                  logging.FileHandler(OUTPUTS / "pipeline.log", encoding="utf-8")])
    params = {"DATABASE": DATABASE, "STAGING": str(ROOT / "data" / "staging")}
    t0 = time.time()

    def step(code: str, desc: str, fn) -> None:
        if code < start_from:
            return
        t = time.time()
        log.info("▶ %s %s", code, desc)
        fn()
        log.info("✔ %s 完成，用时 %.1f 秒", code, time.time() - t)

    step("00", "建库和分层", lambda: run_sql_file(SQL_DIR / "00_create_database.sql", connect(None), params))
    conn = connect()

    def load():
        manifest = prepare_staging.main()
        run_sql_file(SQL_DIR / "01_ods_load.sql", conn, params)
        record_load(conn, manifest)

    def checks():
        run_sql_file(SQL_DIR / "02_quality_checks.sql", conn, params)
        quality_gate(conn, "原始层质量检查")

    def layer(name: str, file: str):
        def run():
            run_sql_file(SQL_DIR / file, conn, params)
            quality_gate(conn, name)
        return run

    def ab():
        from analysis import ab_tests
        ab_tests.main()

    step("01", "原始层：转换文件格式并导入", load)
    step("02", "原始层质量检查", checks)
    step("03", "明细层（类型、空值、渠道、落地页、漏斗）", layer("明细层", "03_dwd.sql"))
    step("04", "汇总层", layer("汇总层", "04_dws.sql"))
    step("05", "应用层", layer("应用层", "05_ads.sql"))
    step("06", "A/B 测试评估", ab)
    step("07", "导出结果", lambda: export(conn))
    summary = query("SELECT severity, COUNT(*) AS checks, SUM(CASE WHEN failed_rows = 0 THEN 1 ELSE 0 END) AS passed "
                    "FROM dq.check_results GROUP BY severity", conn)
    (OUTPUTS / "pipeline_summary.json").write_text(
        json.dumps({"seconds": round(time.time() - t0, 1), "checks": summary.to_dict("records")},
                   ensure_ascii=False, default=int, indent=2), encoding="utf-8")
    log.info("全部完成，用时 %.1f 秒", time.time() - t0)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="start", default="00", help="从第几步开始（00～07）")
    main(ap.parse_args().start)
