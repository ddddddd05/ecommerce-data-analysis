/* 05 应用层（ads）：每张表直接回答一个业务问题（问题清单见 docs/01_业务问题与分析框架.md）。
   报告和看板只读这一层。A/B 测试的显著性检验需要统计计算，由 analysis/ab_tests.py 写入 ads.ab_test_results。

   约定：
   - 比率统一保存为小数（0.0705 = 7.05%），展示时再格式化；
   - 所有除法的分母都用 NULLIF(分母, 0) 保护：分母为 0 时结果为 NULL，不会报错，也不会被误读成 0；
   - 不完整月份按数据实际覆盖的日期动态判断（某月的第一条访问晚于月初、或最后一条早于月末），
     以后追加新数据不需要改脚本；
   - “最近一个完整年度”（漏斗、新老访客、时段分析用）同样从数据推算，不写死年份；
     数据还不足一个完整年度时，退回最近一年。
*/
USE [{{DATABASE}}];
GO
SET DATEFIRST 1;   -- 周一 = 1
GO
IF OBJECT_ID(N'ads.kpi_monthly')        IS NOT NULL DROP TABLE ads.kpi_monthly;
IF OBJECT_ID(N'ads.kpi_quarterly')      IS NOT NULL DROP TABLE ads.kpi_quarterly;
IF OBJECT_ID(N'ads.kpi_yearly')         IS NOT NULL DROP TABLE ads.kpi_yearly;
IF OBJECT_ID(N'ads.channel_yearly')     IS NOT NULL DROP TABLE ads.channel_yearly;
IF OBJECT_ID(N'ads.channel_type_quarterly') IS NOT NULL DROP TABLE ads.channel_type_quarterly;
IF OBJECT_ID(N'ads.paid_search_device') IS NOT NULL DROP TABLE ads.paid_search_device;
IF OBJECT_ID(N'ads.funnel_device')      IS NOT NULL DROP TABLE ads.funnel_device;
IF OBJECT_ID(N'ads.product_quarterly')  IS NOT NULL DROP TABLE ads.product_quarterly;
IF OBJECT_ID(N'ads.cross_sell')         IS NOT NULL DROP TABLE ads.cross_sell;
IF OBJECT_ID(N'ads.refund_monthly')     IS NOT NULL DROP TABLE ads.refund_monthly;
IF OBJECT_ID(N'ads.repeat_visitors')    IS NOT NULL DROP TABLE ads.repeat_visitors;
IF OBJECT_ID(N'ads.traffic_heatmap')    IS NOT NULL DROP TABLE ads.traffic_heatmap;
GO

/* ---------- Q1 整体经营：月 / 季 / 年 ---------- */
WITH m AS (               -- 访问侧（以它为主表：有访问的月份一定保留）
    SELECT session_month AS month, SUM(sessions) AS sessions, SUM(orders) AS orders,
           SUM(revenue_usd) AS revenue_usd, SUM(gross_profit_usd) AS gross_profit_usd,
           MIN(session_date) AS first_day, MAX(session_date) AS last_day
    FROM dws.session_daily GROUP BY session_month
), r AS (                 -- 商品侧：售出件数、退款
    SELECT order_month AS month, SUM(refund_amount_usd) AS refund_amount_usd,
           SUM(items_refunded) AS items_refunded, SUM(items_sold) AS items_sold
    FROM dws.order_item_monthly GROUP BY order_month
)
SELECT m.month, YEAR(m.month) AS year,
       CAST(YEAR(m.month) AS VARCHAR(4)) + 'Q' + CAST(DATEPART(QUARTER, m.month) AS VARCHAR(1)) AS quarter,
       m.sessions, m.orders, m.revenue_usd, m.gross_profit_usd,
       ISNULL(r.refund_amount_usd, 0) AS refund_amount_usd,
       ISNULL(r.items_sold, 0)        AS items_sold,
       ISNULL(r.items_refunded, 0)    AS items_refunded,
       CAST(m.orders * 1.0 / NULLIF(m.sessions, 0) AS DECIMAL(9,4))          AS cvr,
       CAST(m.revenue_usd / NULLIF(m.orders, 0) AS DECIMAL(9,2))             AS aov_usd,
       CAST(m.revenue_usd / NULLIF(m.sessions, 0) AS DECIMAL(9,2))           AS revenue_per_session_usd,
       CAST(m.gross_profit_usd / NULLIF(m.revenue_usd, 0) AS DECIMAL(9,4))   AS gross_margin,
       CAST(r.items_refunded * 1.0 / NULLIF(r.items_sold, 0) AS DECIMAL(9,4)) AS item_refund_rate,
       m.first_day, m.last_day,
       CASE WHEN m.first_day > m.month
              OR m.last_day < DATEADD(DAY, -1, DATEADD(MONTH, 1, m.month)) THEN 1 ELSE 0 END AS is_partial
INTO ads.kpi_monthly
FROM m LEFT JOIN r ON r.month = m.month;
GO

SELECT quarter, MIN(month) AS quarter_start, SUM(sessions) AS sessions, SUM(orders) AS orders,
       SUM(revenue_usd) AS revenue_usd, SUM(gross_profit_usd) AS gross_profit_usd,
       SUM(refund_amount_usd) AS refund_amount_usd,
       CAST(SUM(orders) * 1.0 / NULLIF(SUM(sessions), 0) AS DECIMAL(9,4))           AS cvr,
       CAST(SUM(revenue_usd) / NULLIF(SUM(orders), 0) AS DECIMAL(9,2))              AS aov_usd,
       CAST(SUM(revenue_usd) / NULLIF(SUM(sessions), 0) AS DECIMAL(9,2))            AS revenue_per_session_usd,
       CAST(SUM(gross_profit_usd) / NULLIF(SUM(revenue_usd), 0) AS DECIMAL(9,4))    AS gross_margin,
       CAST(SUM(items_refunded) * 1.0 / NULLIF(SUM(items_sold), 0) AS DECIMAL(9,4)) AS item_refund_rate,
       -- 季度不完整：含不完整月份，或不足 3 个月
       CASE WHEN MAX(is_partial) = 1 OR COUNT(*) < 3 THEN 1 ELSE 0 END AS is_partial
INTO ads.kpi_quarterly
FROM ads.kpi_monthly GROUP BY quarter;
GO

SELECT year, COUNT(*) AS months, SUM(sessions) AS sessions, SUM(orders) AS orders,
       SUM(revenue_usd) AS revenue_usd, SUM(gross_profit_usd) AS gross_profit_usd,
       SUM(refund_amount_usd) AS refund_amount_usd,
       CAST(SUM(orders) * 1.0 / NULLIF(SUM(sessions), 0) AS DECIMAL(9,4))           AS cvr,
       CAST(SUM(revenue_usd) / NULLIF(SUM(orders), 0) AS DECIMAL(9,2))              AS aov_usd,
       CAST(SUM(revenue_usd) / NULLIF(SUM(sessions), 0) AS DECIMAL(9,2))            AS revenue_per_session_usd,
       CAST(SUM(gross_profit_usd) / NULLIF(SUM(revenue_usd), 0) AS DECIMAL(9,4))    AS gross_margin,
       CAST(SUM(items_refunded) * 1.0 / NULLIF(SUM(items_sold), 0) AS DECIMAL(9,4)) AS item_refund_rate,
       CASE WHEN MAX(is_partial) = 1 OR COUNT(*) < 12 THEN 1 ELSE 0 END AS is_partial
INTO ads.kpi_yearly
FROM ads.kpi_monthly GROUP BY year;
GO

/* ---------- Q2 渠道：每年各渠道的规模、占比、转化、每次访问带来的收入 ---------- */
SELECT YEAR(session_date) AS year, channel, channel_type,
       SUM(sessions) AS sessions,
       CAST(SUM(sessions) * 1.0 / NULLIF(SUM(SUM(sessions)) OVER (PARTITION BY YEAR(session_date)), 0)
            AS DECIMAL(9,4)) AS session_share,
       SUM(orders) AS orders,
       CAST(SUM(orders) * 1.0 / NULLIF(SUM(sessions), 0) AS DECIMAL(9,4))  AS cvr,
       SUM(revenue_usd) AS revenue_usd,
       CAST(SUM(revenue_usd) / NULLIF(SUM(sessions), 0) AS DECIMAL(9,2))   AS revenue_per_session_usd,
       CAST(SUM(bounces) * 1.0 / NULLIF(SUM(sessions), 0) AS DECIMAL(9,4)) AS bounce_rate
INTO ads.channel_yearly
FROM dws.session_daily
GROUP BY YEAR(session_date), channel, channel_type;
GO

/* 流量结构：付费拉新 / 付费品牌词 / 免费流量 各占多少（免费流量和品牌词上升 = 品牌知名度在变强） */
WITH q AS (
    SELECT CAST(YEAR(session_date) AS VARCHAR(4)) + 'Q' + CAST(DATEPART(QUARTER, session_date) AS VARCHAR(1)) AS quarter,
           channel_type, sessions, orders
    FROM dws.session_daily
)
SELECT quarter, channel_type,
       SUM(sessions) AS sessions,
       CAST(SUM(sessions) * 1.0 / NULLIF(SUM(SUM(sessions)) OVER (PARTITION BY quarter), 0) AS DECIMAL(9,4)) AS session_share,
       SUM(orders) AS orders,
       CAST(SUM(orders) * 1.0 / NULLIF(SUM(SUM(orders)) OVER (PARTITION BY quarter), 0) AS DECIMAL(9,4))     AS order_share
INTO ads.channel_type_quarterly
FROM q GROUP BY quarter, channel_type;
GO

/* 付费拉新渠道分设备：G、B 两个搜索引擎和社交广告在电脑端和手机端的转化差异，决定出价怎么调 */
SELECT YEAR(session_date) AS year, channel, device_type,
       SUM(sessions) AS sessions, SUM(orders) AS orders,
       CAST(SUM(orders) * 1.0 / NULLIF(SUM(sessions), 0) AS DECIMAL(9,4)) AS cvr,
       CAST(SUM(revenue_usd) / NULLIF(SUM(sessions), 0) AS DECIMAL(9,2))  AS revenue_per_session_usd
INTO ads.paid_search_device
FROM dws.session_daily
WHERE channel IN (N'G搜索-非品牌词', N'B搜索-非品牌词', N'社交广告')
GROUP BY YEAR(session_date), channel, device_type;
GO

/* ---------- Q4 转化漏斗：最近一个完整年度，按设备，看顾客在哪一步流失最多 ---------- */
SELECT y.year, d.device_type,
       SUM(d.sessions) AS sessions,
       SUM(d.sessions - d.bounces) AS not_bounced,
       SUM(d.to_products) AS to_products, SUM(d.to_product_detail) AS to_product_detail,
       SUM(d.to_cart) AS to_cart, SUM(d.to_shipping) AS to_shipping, SUM(d.to_billing) AS to_billing,
       SUM(d.orders) AS orders,
       CAST(SUM(d.to_products) * 1.0 / NULLIF(SUM(d.sessions), 0) AS DECIMAL(9,4))        AS rate_landing_to_products,
       CAST(SUM(d.to_product_detail) * 1.0 / NULLIF(SUM(d.to_products), 0) AS DECIMAL(9,4)) AS rate_products_to_detail,
       CAST(SUM(d.to_cart) * 1.0 / NULLIF(SUM(d.to_product_detail), 0) AS DECIMAL(9,4))   AS rate_detail_to_cart,
       CAST(SUM(d.to_shipping) * 1.0 / NULLIF(SUM(d.to_cart), 0) AS DECIMAL(9,4))         AS rate_cart_to_shipping,
       CAST(SUM(d.to_billing) * 1.0 / NULLIF(SUM(d.to_shipping), 0) AS DECIMAL(9,4))      AS rate_shipping_to_billing,
       CAST(SUM(d.orders) * 1.0 / NULLIF(SUM(d.to_billing), 0) AS DECIMAL(9,4))           AS rate_billing_to_order,
       CAST(SUM(d.orders) * 1.0 / NULLIF(SUM(d.sessions), 0) AS DECIMAL(9,4))             AS cvr
INTO ads.funnel_device
FROM dws.session_daily d
JOIN (SELECT ISNULL((SELECT MAX(year) FROM ads.kpi_yearly WHERE is_partial = 0), (SELECT MAX(year) FROM ads.kpi_yearly)) AS year) y ON YEAR(d.session_date) = y.year
GROUP BY y.year, d.device_type;
GO

/* ---------- Q5 商品：季度销量与收入结构、交叉销售、退款率 ---------- */
WITH q AS (
    SELECT CAST(YEAR(order_month) AS VARCHAR(4)) + 'Q' + CAST(DATEPART(QUARTER, order_month) AS VARCHAR(1)) AS quarter,
           product_id, product_name, items_sold, revenue_usd, cogs_usd
    FROM dws.order_item_monthly
)
SELECT quarter, product_id, product_name,
       SUM(items_sold) AS items_sold, SUM(revenue_usd) AS revenue_usd,
       SUM(revenue_usd - cogs_usd) AS gross_profit_usd,
       CAST(SUM(revenue_usd - cogs_usd) / NULLIF(SUM(revenue_usd), 0) AS DECIMAL(9,4)) AS gross_margin,
       CAST(SUM(revenue_usd) / NULLIF(SUM(SUM(revenue_usd)) OVER (PARTITION BY quarter), 0) AS DECIMAL(9,4)) AS revenue_share
INTO ads.product_quarterly
FROM q GROUP BY quarter, product_id, product_name;
GO

/* 交叉销售：最后一款商品上架之后（所有商品都在售），按主商品看，顾客还会顺带买哪一款 */
WITH since AS (SELECT MAX(launched_at) AS start_at FROM dwd.dim_product),
o AS (
    SELECT o.order_id, o.primary_product_id
    FROM dwd.fact_order o CROSS JOIN since
    WHERE o.ordered_at >= since.start_at
), x AS (
    SELECT o.primary_product_id, i.product_id AS cross_product_id, COUNT(*) AS orders
    FROM o JOIN dwd.fact_order_item i ON i.order_id = o.order_id AND i.is_primary_item = 0
    GROUP BY o.primary_product_id, i.product_id
)
SELECT (SELECT start_at FROM since) AS period_start,
       p.product_id AS primary_product_id, p.product_name AS primary_product,
       t.orders AS primary_orders,
       cp.product_id AS cross_product_id, cp.product_name AS cross_product,
       ISNULL(x.orders, 0) AS cross_orders,
       CAST(ISNULL(x.orders, 0) * 1.0 / NULLIF(t.orders, 0) AS DECIMAL(9,4)) AS cross_sell_rate
INTO ads.cross_sell
FROM (SELECT primary_product_id, COUNT(*) AS orders FROM o GROUP BY primary_product_id) t
JOIN dwd.dim_product p ON p.product_id = t.primary_product_id
CROSS JOIN dwd.dim_product cp
LEFT JOIN x ON x.primary_product_id = t.primary_product_id AND x.cross_product_id = cp.product_id
WHERE cp.product_id <> p.product_id;
GO

/* 各商品月度退款率（按下单月份），用于发现质量问题批次 */
SELECT order_month, product_id, product_name,
       SUM(items_sold) AS items_sold, SUM(items_refunded) AS items_refunded,
       CAST(SUM(items_refunded) * 1.0 / NULLIF(SUM(items_sold), 0) AS DECIMAL(9,4)) AS refund_rate,
       SUM(refund_amount_usd) AS refund_amount_usd
INTO ads.refund_monthly
FROM dws.order_item_monthly
GROUP BY order_month, product_id, product_name;
GO

/* ---------- Q6 回访顾客：最近一个完整年度，新访客 vs 回访，各自从哪个渠道来、转化如何 ---------- */
SELECT y.year,
       CASE d.is_repeat_session WHEN 1 THEN N'回访' ELSE N'首次访问' END AS visitor_type,
       d.channel,
       SUM(d.sessions) AS sessions,
       CAST(SUM(d.sessions) * 1.0 / NULLIF(SUM(SUM(d.sessions)) OVER (PARTITION BY d.is_repeat_session), 0)
            AS DECIMAL(9,4)) AS share_within_type,
       SUM(d.orders) AS orders,
       CAST(SUM(d.orders) * 1.0 / NULLIF(SUM(d.sessions), 0) AS DECIMAL(9,4)) AS cvr,
       SUM(d.revenue_usd) AS revenue_usd,       -- 带上收入原值，前端合计时不用拿四舍五入后的比率反推
       CAST(SUM(d.revenue_usd) / NULLIF(SUM(d.sessions), 0) AS DECIMAL(9,2))  AS revenue_per_session_usd
INTO ads.repeat_visitors
FROM dws.session_daily d
JOIN (SELECT ISNULL((SELECT MAX(year) FROM ads.kpi_yearly WHERE is_partial = 0), (SELECT MAX(year) FROM ads.kpi_yearly)) AS year) y ON YEAR(d.session_date) = y.year
GROUP BY y.year, d.is_repeat_session, d.channel;
GO

/* ---------- Q7 时段：最近一个完整年度，每个“星期几 × 小时”平均有多少次访问（客服排班用） ---------- */
/* 分母是“这一年里有几个周一/周二……”，而不是“这个小时有访问的天数”，
   否则某天某小时恰好 0 次访问时，这一天会被漏掉、平均值偏高 */
WITH y AS (SELECT ISNULL((SELECT MAX(year) FROM ads.kpi_yearly WHERE is_partial = 0), (SELECT MAX(year) FROM ads.kpi_yearly)) AS year),
days AS (
    SELECT DATEPART(WEEKDAY, s.session_date) AS weekday, COUNT(DISTINCT s.session_date) AS n_days
    FROM dwd.fact_session s JOIN y ON YEAR(s.session_date) = y.year
    GROUP BY DATEPART(WEEKDAY, s.session_date)
),
h AS (
    SELECT DATEPART(WEEKDAY, s.session_start) AS weekday,      -- 1 = 周一
           DATEPART(HOUR, s.session_start) AS hour, COUNT(*) AS sessions
    FROM dwd.fact_session s JOIN y ON YEAR(s.session_start) = y.year
    GROUP BY DATEPART(WEEKDAY, s.session_start), DATEPART(HOUR, s.session_start)
)
SELECT (SELECT year FROM y) AS year, h.weekday, h.hour, h.sessions, d.n_days,
       CAST(h.sessions * 1.0 / NULLIF(d.n_days, 0) AS DECIMAL(9,1)) AS avg_sessions_per_day
INTO ads.traffic_heatmap
FROM h JOIN days d ON d.weekday = h.weekday;
GO
