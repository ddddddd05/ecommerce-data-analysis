"""不需要数据库的测试：统计方法、文件格式转换、SQL 批次拆分。"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from analysis.stats import sample_ratio_test, two_proportion_test  # noqa: E402
from pipeline.db import split_batches  # noqa: E402
from pipeline.prepare_staging import convert  # noqa: E402


# ---------- 统计方法 ----------
def test_two_proportion_test_matches_hand_calculation():
    # A：1000 次访问 100 单（10%），B：1000 次 130 单（13%）
    r = two_proportion_test(100, 1000, 130, 1000)
    assert r.diff == pytest.approx(0.03)
    assert r.relative_lift == pytest.approx(0.30)
    # 合并比例 0.115，标准误 sqrt(0.115*0.885*2/1000)=0.014267 → z=2.1027
    assert r.z == pytest.approx(2.1027, abs=1e-3)
    assert r.p_value == pytest.approx(0.0355, abs=1e-3)
    assert r.significant
    assert r.ci_low < r.diff < r.ci_high and r.ci_low > 0      # 显著时区间不含 0


def test_two_proportion_test_not_significant_when_same():
    r = two_proportion_test(50, 1000, 50, 1000)
    assert r.diff == 0 and r.p_value == pytest.approx(1.0) and not r.significant
    assert r.ci_low < 0 < r.ci_high


def test_two_proportion_test_rejects_empty_group():
    with pytest.raises(ValueError):
        two_proportion_test(0, 0, 1, 10)


def test_required_sample_size():
    from analysis.stats import required_sample_size
    # 教科书例子：10% → 12%，α=0.05、功效 80%，每组约 3,841
    assert required_sample_size(0.10, 0.12) == pytest.approx(3841, abs=5)
    assert required_sample_size(0.10, 0.11) > required_sample_size(0.10, 0.12)   # 差异越小需要越多
    with pytest.raises(ValueError):
        required_sample_size(0.1, 0.1)


def test_sample_ratio_test():
    assert sample_ratio_test(5000, 5000) == pytest.approx(1.0)
    assert sample_ratio_test(5000, 5100) > 0.001          # 1% 的偏差属于正常波动
    assert sample_ratio_test(5000, 6000) < 0.001          # 45% / 55%：分流有问题


# ---------- 文件格式转换 ----------
def test_convert_removes_quotes_and_keeps_rows(tmp_path):
    raw, stg = tmp_path / "raw", tmp_path / "stg"
    raw.mkdir()
    (raw / "website_pageviews.csv").write_text(
        'website_pageview_id,created_at,website_session_id,pageview_url\n'
        '1,"2012-03-19 08:04:16",1,/home\n2,"2012-03-19 08:16:49",2,/home\n', encoding="utf-8")
    info = convert("website_pageviews", raw, stg)
    assert info["rows"] == 2
    lines = (stg / "website_pageviews.tsv").read_text(encoding="ascii").splitlines()
    assert lines[1] == "1\t2012-03-19 08:04:16\t1\t/home"     # 引号去掉了，值没变


def test_convert_fails_on_wrong_column_count(tmp_path):
    raw = tmp_path / "raw"
    raw.mkdir()
    (raw / "products.csv").write_text("product_id,created_at,product_name\n1,2012-03-19\n", encoding="utf-8")
    with pytest.raises(ValueError, match="第 2 行"):
        convert("products", raw, tmp_path / "stg")


# ---------- SQL 批次 ----------
def test_split_batches_on_go_lines_only():
    sql = "SELECT 1;\nGO\nSELECT 'GOOD';\n  go  \nSELECT 3"
    assert split_batches(sql) == ["SELECT 1;", "SELECT 'GOOD';", "SELECT 3"]


# ---------- 看板接口（用导出的 CSV，不需要数据库） ----------
def test_dashboard_reads_whitelisted_tables_from_csv(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient
    import dashboard.app as dash
    (tmp_path / "kpi_yearly.csv").write_text("year,revenue_usd,cvr\n2014,1075612.19,0.0722\n", encoding="utf-8")
    monkeypatch.setattr(dash, "OUTPUTS", tmp_path)
    client = TestClient(dash.create_app(source="csv"))
    body = client.get("/api/tables/kpi_yearly").json()
    assert body["source"] == "CSV 导出文件" and body["rows"][0]["revenue_usd"] == 1075612.19
    assert client.get("/api/tables/sys_users").status_code == 404        # 不在白名单
    assert client.get("/api/tables/funnel_device").status_code == 503    # 没有导出文件
