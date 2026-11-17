"""连本机数据库的测试：在流水线跑完之后，抽查各层的数据和口径是否正确。

全部标记为 db：没有 SQL Server 的机器上运行 `pytest -m "not db"` 只跑离线测试。
数据库连不上时这些测试自动跳过（连接在 fixture 里建立，收集用例阶段不连库）。
先运行：python pipeline/run_pipeline.py
这些测试用独立写的 SQL 重新计算关键数字，和各层表里的结果比对。
"""
import sys
from contextlib import closing
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline.db import connect, query  # noqa: E402

pytestmark = pytest.mark.db
_conn = None


@pytest.fixture(scope="module", autouse=True)
def db_conn():
    global _conn
    try:
        conn = connect()
        query("SELECT TOP 1 1 AS x FROM ads.kpi_yearly", conn)
    except Exception as e:  # noqa: BLE001
        pytest.skip(f"数据库不可用或流水线没跑过：{e}")
    with closing(conn):
        _conn = conn
        yield conn
    _conn = None


def one(sql: str, params: list | None = None):
    return query(sql, _conn, params).iloc[0, 0]


def test_all_blocking_checks_passed():
    assert one("SELECT COUNT(*) FROM dq.check_results WHERE severity = N'阻断'") >= 44   # 36 原始层 + 8 层间核对
    assert one("SELECT COUNT(*) FROM dq.check_results WHERE severity = N'阻断' AND failed_rows > 0") == 0


def test_load_matches_files():
    assert one("SELECT COUNT(*) FROM dq.load_log WHERE file_rows <> loaded_rows") == 0
    assert one("SELECT COUNT(*) FROM ods.website_sessions") == 472871
    assert one("SELECT COUNT(*) FROM ods.website_pageviews") == 1188124


def test_landing_page_is_first_pageview():
    """抽 1000 个访问，独立用“最小浏览编号”求落地页，和明细层对比。"""
    mismatch = one("""
        SELECT COUNT(*) FROM (SELECT TOP 1000 session_id, landing_page FROM dwd.fact_session
                              ORDER BY NEWID()) s
        JOIN (SELECT CAST(website_session_id AS INT) AS sid, MIN(CAST(website_pageview_id AS INT)) AS first_pv
              FROM ods.website_pageviews GROUP BY website_session_id) f ON f.sid = s.session_id
        JOIN ods.website_pageviews p ON CAST(p.website_pageview_id AS INT) = f.first_pv
        WHERE p.pageview_url <> s.landing_page""")
    assert mismatch == 0


def test_channel_rules():
    # 有广告标记的不能被归成免费流量；没有标记的按 referer 分成自然搜索 / 直接访问
    assert one("SELECT COUNT(*) FROM dwd.fact_session WHERE utm_source IS NOT NULL "
               "AND channel IN (N'自然搜索', N'直接访问')") == 0
    assert one("SELECT COUNT(*) FROM dwd.fact_session WHERE channel = N'直接访问' AND http_referer IS NOT NULL") == 0
    assert one("SELECT COUNT(*) FROM dwd.fact_session WHERE utm_source IS NULL") == 83328


def test_bounce_means_single_pageview():
    assert one("""SELECT COUNT(*) FROM dwd.fact_session s
                  WHERE is_bounce <> CASE WHEN (SELECT COUNT(*) FROM dwd.fact_pageview p
                                                WHERE p.session_id = s.session_id) = 1 THEN 1 ELSE 0 END
                    AND s.session_id % 50 = 0""") == 0


def test_yearly_kpi_recomputed_from_ods():
    """2014 年的收入、订单、转化率：直接从原始层重新算，和应用层对比。"""
    ods = query("""SELECT COUNT(*) AS orders, SUM(CAST(price_usd AS DECIMAL(12,2))) AS revenue
                   FROM ods.orders WHERE created_at >= '2014-01-01' AND created_at < '2015-01-01'""", _conn)
    sessions = one("SELECT COUNT(*) FROM ods.website_sessions "
                   "WHERE created_at >= '2014-01-01' AND created_at < '2015-01-01'")
    ads = query("SELECT orders, revenue_usd, sessions, cvr FROM ads.kpi_yearly WHERE year = 2014", _conn).iloc[0]
    # 订单按“所属访问”的日期归属；跨年夜的访问可能在次日下单，允许极少量差异
    assert abs(int(ads.orders) - int(ods.orders[0])) <= 5
    assert abs(float(ads.revenue_usd) - float(ods.revenue[0])) < 300
    assert int(ads.sessions) == sessions
    assert float(ads.cvr) == pytest.approx(int(ads.orders) / sessions, abs=1e-4)


def test_partial_months_flagged():
    flagged = set(query("SELECT CONVERT(VARCHAR(7), month, 120) AS m FROM ads.kpi_monthly WHERE is_partial = 1",
                        _conn).m)
    assert flagged == {"2012-03", "2015-03"}


def test_ab_tests_have_balanced_split_and_valid_windows():
    r = query("SELECT * FROM ads.ab_test_results ORDER BY test_id", _conn)
    assert list(r.test_id) == ["T1", "T2", "T3", "T4"]
    assert (r.srm_p_value > 0.001).all()                      # 4 个测试分流都正常
    assert (r.window_start < r.window_end).all()
    t4 = r.set_index("test_id").loc["T4"]
    # 独立重算 T4 实验组的转化率
    cvr_b = one("""SELECT AVG(has_order * 1.0) FROM dwd.fact_session
                   WHERE landing_page = '/lander-5' AND device_type = 'desktop'
                     AND channel IN (N'G搜索-非品牌词', N'B搜索-非品牌词')
                     AND session_start >= ? AND session_start <= ?""",
                [t4.window_start.to_pydatetime(), t4.window_end.to_pydatetime()])
    assert float(cvr_b) == pytest.approx(t4.cvr_b, abs=1e-6)


def test_partial_months_detected_from_data_coverage():
    """不完整月份是按数据覆盖日期判断的：每个被标记的月份，要么不从 1 号开始，要么没到月末。"""
    bad = one("""SELECT COUNT(*) FROM ads.kpi_monthly
                 WHERE is_partial = 1 AND first_day = month
                   AND last_day = DATEADD(DAY, -1, DATEADD(MONTH, 1, month))""")
    assert bad == 0


def test_no_division_by_zero_nulls_in_core_kpis():
    """分母都不为 0 时，NULLIF 保护不应该产生 NULL。"""
    assert one("SELECT COUNT(*) FROM ads.kpi_monthly WHERE cvr IS NULL OR aov_usd IS NULL") == 0


def test_first_product_page_follows_browse_order():
    """看了多个商品页的访问，first_product_page 必须是浏览顺序上的第一个。"""
    mismatch = one("""
        SELECT COUNT(*) FROM dwd.fact_session s
        CROSS APPLY (SELECT TOP 1 p.pageview_url FROM dwd.fact_pageview p
                     WHERE p.session_id = s.session_id AND p.page_type = N'商品详情'
                     ORDER BY p.page_seq) f
        WHERE s.product_detail_views > 1 AND s.first_product_page <> f.pageview_url""")
    assert mismatch == 0


def test_lander3_is_mobile_only_so_not_compared_with_lander2():
    devices = set(query("SELECT DISTINCT device_type FROM dwd.fact_session WHERE landing_page = '/lander-3' "
                        "AND channel <> N'社交广告'", _conn).device_type)
    assert devices == {"mobile"}


def test_repeat_visitors_revenue_reconciles_with_year_total():
    """新老访客表带上收入原值，合计必须等于当年总收入（前端用它算，不再用四舍五入后的比率反推）。"""
    diff = one("""SELECT ABS((SELECT SUM(revenue_usd) FROM ads.repeat_visitors)
                     - (SELECT revenue_usd FROM ads.kpi_yearly
                        WHERE year = (SELECT MAX(year) FROM ads.repeat_visitors)))""")
    assert float(diff) < 0.01
