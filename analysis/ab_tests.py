"""Q3：落地页和支付页的 A/B 测试评估，结果写入 ads.ab_test_results（流水线导出为 outputs/ab_test_results.csv）。

为什么只评估这 4 个测试：先按“落地页 × 渠道 × 设备 × 广告”查了每个页面在什么时间收到哪部分流量
（结果见 docs/04_数据质量与探索记录.md），只有下面 4 组是**同一时间段、同一部分流量、各分一半**，
满足 A/B 测试的前提。/lander-3 只给手机端、/lander-2 只给电脑端，两者流量来源不同，不能当成测试来比。

测试窗口不手写：在指定的流量范围内，取两个页面都在接收流量的时间段（重叠期），避免把“季节变化”
算成“页面效果”。每个测试先做样本比例检验（SRM），分流正常才解读结果。
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from analysis.stats import sample_ratio_test, two_proportion_test  # noqa: E402
from pipeline.db import connect, query  # noqa: E402


@dataclass
class TestSpec:
    test_id: str
    name: str
    page_column: str        # landing_page（落地页测试）或 billing_page（支付页测试）
    page_a: str             # 对照组（原版本）
    page_b: str             # 实验组（新版本）
    segment_sql: str        # 流量范围
    segment_desc: str


TESTS = [
    TestSpec("T1", "首页 vs 新落地页 lander-1", "landing_page", "/home", "/lander-1",
             "channel = N'G搜索-非品牌词'", "G 搜索非品牌词广告（电脑 + 手机）"),
    TestSpec("T2", "支付页 billing vs billing-2", "billing_page", "/billing", "/billing-2",
             "billing_page IS NOT NULL", "所有进入支付页的访问"),
    TestSpec("T3", "落地页 lander-2 vs lander-4", "landing_page", "/lander-2", "/lander-4",
             "channel IN (N'G搜索-非品牌词', N'B搜索-非品牌词') AND device_type = 'desktop'",
             "G/B 搜索非品牌词广告，电脑端"),
    TestSpec("T4", "落地页 lander-2 vs lander-5", "landing_page", "/lander-2", "/lander-5",
             "channel IN (N'G搜索-非品牌词', N'B搜索-非品牌词') AND device_type = 'desktop'",
             "G/B 搜索非品牌词广告，电脑端"),
]


def test_window(spec: TestSpec, conn) -> tuple[pd.Timestamp, pd.Timestamp]:
    """两个页面在这部分流量里都有访问的时间段：[较晚的开始, 较早的结束]。"""
    df = query(f"""SELECT {spec.page_column} AS page, MIN(session_start) AS first_seen,
                          MAX(session_start) AS last_seen
                   FROM dwd.fact_session
                   WHERE {spec.segment_sql} AND {spec.page_column} IN (?, ?)
                   GROUP BY {spec.page_column}""", conn, [spec.page_a, spec.page_b])
    if len(df) != 2:
        raise ValueError(f"{spec.test_id}：两个页面没有都出现在该流量范围内")
    return max(df.first_seen), min(df.last_seen)


def evaluate(spec: TestSpec, conn) -> dict:
    start, end = test_window(spec, conn)
    m = query(f"""SELECT {spec.page_column} AS page, COUNT(*) AS sessions, SUM(is_bounce) AS bounces,
                         SUM(has_order) AS orders, SUM(revenue_usd) AS revenue
                  FROM dwd.fact_session
                  WHERE {spec.segment_sql} AND {spec.page_column} IN (?, ?)
                    AND session_start >= ? AND session_start <= ?
                  GROUP BY {spec.page_column}""",
              conn, [spec.page_a, spec.page_b, start, end]).set_index("page")
    a, b = m.loc[spec.page_a], m.loc[spec.page_b]
    na, nb = int(a.sessions), int(b.sessions)
    cvr = two_proportion_test(int(a.orders), na, int(b.orders), nb)
    is_landing = spec.page_column == "landing_page"
    bounce = two_proportion_test(int(a.bounces), na, int(b.bounces), nb) if is_landing else None
    srm_p = sample_ratio_test(na, nb)
    rps_a, rps_b = float(a.revenue) / na, float(b.revenue) / nb

    if srm_p < 0.001:
        verdict = "分流比例异常，结果不可信"
    elif cvr.significant:
        verdict = f"{'新版' if cvr.diff > 0 else '原版'}胜出（转化率差异显著）"
    elif bounce is not None and bounce.significant:
        verdict = (f"新版跳出率显著{'降低' if bounce.diff < 0 else '升高'}，"
                   f"转化率差异不显著（样本不足以下结论）")
    else:
        verdict = "无显著差异"

    impact = rollout_impact(spec, end, cvr.diff, rps_b - rps_a, conn) if (
        cvr.significant and cvr.diff > 0 and srm_p >= 0.001) else {}
    return {
        "test_id": spec.test_id, "test_name": spec.name, "segment": spec.segment_desc,
        "page_a": spec.page_a, "page_b": spec.page_b,
        "window_start": start, "window_end": end, "days": (end - start).days + 1,
        "sessions_a": na, "sessions_b": nb, "share_b": nb / (na + nb), "srm_p_value": srm_p,
        "orders_a": int(a.orders), "orders_b": int(b.orders),
        "cvr_a": cvr.rate_a, "cvr_b": cvr.rate_b, "cvr_diff": cvr.diff, "cvr_lift": cvr.relative_lift,
        "cvr_ci_low": cvr.ci_low, "cvr_ci_high": cvr.ci_high, "cvr_p_value": cvr.p_value,
        "bounce_a": bounce.rate_a if bounce else None, "bounce_b": bounce.rate_b if bounce else None,
        "bounce_p_value": bounce.p_value if bounce else None,
        "rps_a": rps_a, "rps_b": rps_b,
        "verdict": verdict,
        "rollout_sessions": impact.get("sessions"), "est_extra_orders": impact.get("extra_orders"),
        "est_extra_revenue_usd": impact.get("extra_revenue"),
    }


def rollout_impact(spec: TestSpec, test_end, cvr_diff: float, rps_diff: float, conn) -> dict:
    """粗略估算：测试结束后，新版本在同一流量范围里一共接待了多少访问 × 测试测出的提升。

    假设提升幅度在测试后保持不变（实际会随季节、广告变化），所以只作为量级参考。
    """
    n = query(f"""SELECT COUNT(*) AS n FROM dwd.fact_session
                  WHERE {spec.segment_sql} AND {spec.page_column} = ? AND session_start > ?""",
              conn, [spec.page_b, test_end]).n.iloc[0]
    return {"sessions": int(n), "extra_orders": round(n * cvr_diff), "extra_revenue": round(n * rps_diff, 2)}


DDL = """
IF OBJECT_ID(N'ads.ab_test_results') IS NOT NULL DROP TABLE ads.ab_test_results;
CREATE TABLE ads.ab_test_results (
    test_id VARCHAR(5) PRIMARY KEY, test_name NVARCHAR(100), segment NVARCHAR(100),
    page_a VARCHAR(50), page_b VARCHAR(50), window_start DATETIME, window_end DATETIME, days INT,
    sessions_a INT, sessions_b INT, share_b FLOAT, srm_p_value FLOAT,
    orders_a INT, orders_b INT, cvr_a FLOAT, cvr_b FLOAT, cvr_diff FLOAT, cvr_lift FLOAT,
    cvr_ci_low FLOAT, cvr_ci_high FLOAT, cvr_p_value FLOAT,
    bounce_a FLOAT, bounce_b FLOAT, bounce_p_value FLOAT, rps_a FLOAT, rps_b FLOAT,
    verdict NVARCHAR(100), rollout_sessions INT, est_extra_orders INT, est_extra_revenue_usd FLOAT
);
"""


def main() -> pd.DataFrame:
    """评估 4 个测试并写入 ads.ab_test_results。导出 CSV 由流水线第 07 步统一完成（outputs/ab_test_results.csv）。"""
    conn = connect()
    try:
        results = pd.DataFrame([evaluate(t, conn) for t in TESTS])
        cur = conn.cursor()
        cur.execute(DDL)
        cols = list(results.columns)
        rows = [tuple(None if pd.isna(v) else (v.to_pydatetime() if isinstance(v, pd.Timestamp) else v)
                      for v in r) for r in results.itertuples(index=False)]
        cur.executemany(f"INSERT ads.ab_test_results ({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})",
                        rows)
    finally:
        conn.close()
    for r in results.itertuples():
        print(f"{r.test_id} {r.test_name}: 转化率 {r.cvr_a:.2%} → {r.cvr_b:.2%}，p={r.cvr_p_value:.4f}，"
              f"分流 {r.share_b:.1%}（SRM p={r.srm_p_value:.3f}）→ {r.verdict}")
    return results


if __name__ == "__main__":
    main()
