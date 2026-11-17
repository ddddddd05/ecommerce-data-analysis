# 电商经营分析：数据仓库 + A/B 测试 + 经营看板

用一家网上玩具店 3 年的数据（47 万次访问、119 万次浏览、3.2 万笔订单），按企业数据分析的流程完成：**数据质量检查 → 分层建模 → 指标口径统一 → 业务问题分析 → A/B 测试显著性检验 → 经营报告 → 看板**。

> 数据来自 [Maven Analytics Data Playground](https://mavenanalytics.io/data-playground/toy-store-e-commerce-database)（Maven Fuzzy Factory，**虚构公司的教学数据**），不随仓库分发，请自行下载。

## 核心发现（详见 [经营分析报告](reports/经营分析报告.md)）

| 发现 | 数据 |
|---|---|
| 2014 年收入比 2013 年增长 174%：访问量 ×2.07、转化率 ×1.09、客单价 ×1.21 | `ads.kpi_yearly` |
| 品牌词 + 免费流量的订单占比从 16.1%（2012Q2）升到 33.5%（2015Q1），对拉新广告的依赖下降 | `ads.channel_type_quarterly` |
| 新支付页让支付页下单率 45.1% → 62.1%；落地页 lander-5 让电脑端转化率 8.37% → 10.02%；lander-4 反而更差 | `ads.ab_test_results` |
| 手机端转化率 3.31%，不到电脑端（9.18%）的四成，漏斗每一步都更差 | `ads.funnel_device` |
| 2014 年 8～9 月主力商品退款率达到 13.8%，是同年其他月份的 2～5 倍 | `ads.refund_monthly` |
| 约 20% 的订单会顺带购买低价高毛利的 Mini bear | `ads.cross_sell` |

## 分层架构（SQL Server）

```
data/raw/*.csv ──► prepare_staging.py（只改文件格式）──► BULK INSERT
                                                            │
 ods  原始层  6 张表，全部 VARCHAR，和源文件一致 ◄───────────┘
   │  dq  质量检查：28 项阻断 + 6 项警告 + 3 项信息，阻断项不通过流水线停止
   ▼
 dwd  明细层  类型转换、空值处理；派生渠道、落地页、跳出、漏斗步骤、是否下单、退款
   │  + 6 项层间核对（访问数、订单数、收入、退款与原始层一致；规则无遗漏）
   ▼
 dws  汇总层  访问日汇总（日期 × 渠道 × 设备 × 新老访客 × 落地页）、商品月汇总
   │  + 2 项层间核对
   ▼
 ads  应用层  13 张表，每张回答一个业务问题；A/B 测试结果由 Python 统计后写入
   ▼
 reports/经营分析报告.md      dashboard/（FastAPI + ECharts）      outputs/*.csv
```

## 企业化做法

| 做法 | 在哪里 | 为什么 |
|---|---|---|
| 先定业务问题和口径，再写 SQL | [docs/01](docs/01_业务问题与分析框架.md)、[docs/02](docs/02_指标口径.md) | 避免“不同人算出不同的转化率” |
| 数据字典 | [docs/03](docs/03_数据字典.md) | 新人能看懂每张表、每个字段 |
| 原始层原样保留 | `sql/01_ods_load.sql` | 加工规则写错了可以重新加工，能追溯 |
| 质量关卡 | `sql/02_quality_checks.sql`、`run_pipeline.py` 的 `quality_gate` | 有问题的数据不会流到报告里 |
| 口径只在明细层定义一次 | `sql/03_dwd.sql` | 所有报表口径一致 |
| 层间核对 | 03、04 脚本末尾 | 每加工一层都和上一层对账 |
| 脚本编号、可重复运行、一键流水线 | `sql/00～05`、`pipeline/run_pipeline.py` | 换人、换电脑都能跑出同样结果（约 77 秒） |
| A/B 测试先查分流、只比同期同流量 | `analysis/ab_tests.py`、[docs/04](docs/04_数据质量与探索记录.md) | 避免把设备差异、季节差异当成页面效果 |
| 显著性、置信区间、样本量 | `analysis/stats.py` | 区分“真提升”和“随机波动”，测试前算好要跑多久 |
| 自动化测试 | `tests/` | 用独立 SQL 复算关键数字 |
| 报告：结论 + 依据 + 建议 + 局限 | `reports/经营分析报告.md` | 每个结论都标注出自哪张表，建议都说明怎么验证 |

## 快速开始

需要 Windows + SQL Server（2008 R2 及以上，Windows 身份验证）+ Python 3.11+。

```bash
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
# 把下载的 Maven Fuzzy Factory 数据解压到 data/raw/
python pipeline/run_pipeline.py            # 建库、导入、检查、分层、A/B 测试、导出
python -m pytest -q                        # 18 个测试
uvicorn dashboard.app:app --port 8100      # 打开 http://localhost:8100
```

- 服务器和数据库名可以用环境变量 `MSSQL_SERVER`、`MSSQL_DATABASE` 修改（默认 `localhost`、`MavenFuzzyFactory`）；
- 看板优先读数据库，连不上时读 `outputs/*.csv`；
- 只重跑后面几步：`python pipeline/run_pipeline.py --from 03`。

## 项目结构

```
sql/
  00_create_database.sql   建库、建 ods/dwd/dws/ads/dq 五个分层
  01_ods_load.sql          原始层建表 + BULK INSERT
  02_quality_checks.sql    原始层质量检查（唯一性、格式、关联、业务规则、完整性）
  03_dwd.sql               明细层：5 张表 + 层间核对
  04_dws.sql               汇总层：2 张表 + 层间核对
  05_ads.sql               应用层：12 张业务表
pipeline/
  db.py                    连接 SQL Server、执行 .sql 文件、查询
  prepare_staging.py       CSV → 制表符文件（SQL Server 2008 不识别 CSV 引号）
  run_pipeline.py          一键流水线 + 质量关卡 + 导出
analysis/
  stats.py                 两比例 z 检验、置信区间、样本比例检验、样本量计算
  ab_tests.py              4 个 A/B 测试的评估
dashboard/                 看板（FastAPI 只读应用层 + ECharts 页面）
docs/                      业务问题、指标口径、数据字典、质量与探索记录
reports/经营分析报告.md    最终报告
tests/                     离线测试 + 数据库抽查
```

## 局限

- 虚构的教学数据，非常干净（所有质量检查都通过）；真实数据会更复杂，这套检查的价值在于每次更新数据都自动执行；
- 数据里没有广告花费，无法计算投入产出比，渠道建议基于“每次访问带来的收入”；
- 前后对比（如手机专用落地页上线前后）不是随机实验，只作参考；
- SQL 按 SQL Server 2008 语法编写（不用 LAG、IIF 等新函数），在新版本上也能运行。
