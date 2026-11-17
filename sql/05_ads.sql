/* 05 应用层（ads）：每张表直接回答一个业务问题（问题清单见 docs/01_业务问题与分析框架.md）。
   报告和看板只读这一层。A/B 测试的显著性检验需要统计计算，由 analysis/ab_tests.py 写入 ads.ab_test_results。
   比率统一保存为小数（0.0705 = 7.05%），展示时再格式化。
   数据首月（2012-03，从 19 日开始）和末月（2015-03，到 19 日为止）不完整，用 is_partial 标出。
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
WITH m AS (
    SELECT session_month AS month, SUM(sessions) AS sessions, SUM(orders) AS orders,
           SUM(revenue_usd) AS revenue_usd, SUM(gross_profit_usd) AS gross_profit_usd
    FROM dws.session_daily GROUP BY session_month
), r AS (
    SELECT order_month AS month, SUM(refund_amount_usd) AS refund_amount_usd,
           SUM(items_refunded) AS items_refunded, SUM(items_sold) AS items_sold
    FROM dws.order_item_monthly GROUP BY order_month
)
SELECT m.month, YEAR(m.month) AS year,
       CAST(YEAR(m.month) AS VARCHAR(4)) + 'Q' + CAST(DATEPART(QUARTER, m.month) AS VARCHAR(1)) AS quarter,
       m.sessions, m.orders, m.revenue_usd, m.gross_profit_usd, r.refund_amount_usd,
       r.items_sold, r.items_refunded,
       CAST(m.orders * 1.0 / m.sessions AS DECIMAL(9,4))           AS cvr,
       CAST(m.revenue_usd / m.orders AS DECIMAL(9,2))              AS aov_usd,
       CAST(m.revenue_usd / m.sessions AS DECIMAL(9,2))            AS revenue_per_session_usd,
       CAST(m.gross_profit_usd / m.revenue_usd AS DECIMAL(9,4))    AS gross_margin,
       CAST(r.items_refunded * 1.0 / r.items_sold AS DECIMAL(9,4)) AS item_refund_rate,
       CASE WHEN m.month IN ('2012-03-01', '2015-03-01') THEN 1 ELSE 0 END AS is_partial
INTO ads.kpi_monthly
FROM m JOIN r ON r.month = m.month;
GO

SELECT quarter, MIN(month) AS quarter_start, SUM(sessions) AS sessions, SUM(orders) AS orders,
       SUM(revenue_usd) AS revenue_usd, SUM(gross_profit_usd) AS gross_profit_usd,
       SUM(refund_amount_usd) AS refund_amount_usd,
       CAST(SUM(orders) * 1.0 / SUM(sessions) AS DECIMAL(9,4))         AS cvr,
       CAST(SUM(revenue_usd) / SUM(orders) AS DECIMAL(9,2))            AS aov_usd,
       CAST(SUM(revenue_usd) / SUM(sessions) AS DECIMAL(9,2))          AS revenue_per_session_usd,
       CAST(SUM(gross_profit_usd) / SUM(revenue_usd) AS DECIMAL(9,4))  AS gross_margin,
       CAST(SUM(items_refunded) * 1.0 / SUM(items_sold) AS DECIMAL(9,4)) AS item_refund_rate,
       MAX(is_partial) AS is_partial
INTO ads.kpi_quarterly
FROM ads.kpi_monthly GROUP BY quarter;
GO

SELECT year, COUNT(*) AS months, SUM(sessions) AS sessions, SUM(orders) AS orders,
       SUM(revenue_usd) AS revenue_usd, SUM(gross_profit_usd) AS gross_profit_usd,
       SUM(refund_amount_usd) AS refund_amount_usd,
       CAST(SUM(orders) * 1.0 / SUM(sessions) AS DECIMAL(9,4))         AS cvr,
       CAST(SUM(revenue_usd) / SUM(orders) AS DECIMAL(9,2))            AS aov_usd,
       CAST(SUM(revenue_usd) / SUM(sessions) AS DECIMAL(9,2))          AS revenue_per_session_usd,
       CAST(SUM(gross_profit_usd) / SUM(revenue_usd) AS DECIMAL(9,4))  AS gross_margin,
       CAST(SUM(items_refunded) * 1.0 / SUM(items_sold) AS DECIMAL(9,4)) AS item_refund_rate,
       MAX(is_partial) AS is_partial
INTO ads.kpi_yearly
FROM ads.kpi_monthly GROUP BY year;
GO

/* ---------- Q2 渠道：每年各渠道的规模、占比、转化、每次访问带来的收入 ---------- */
SELECT YEAR(session_date) AS year, channel, channel_type,
       SUM(sessions) AS sessions,
       CAST(SUM(sessions) * 1.0 / SUM(SUM(sessions)) OVER (PARTITION BY YEAR(session_date)) AS DECIMAL(9,4)) AS session_share,
       SUM(orders) AS orders,
       CAST(SUM(orders) * 1.0 / SUM(sessions) AS DECIMAL(9,4)) AS cvr,
       SUM(revenue_usd) AS revenue_usd,
       CAST(SUM(revenue_usd) / SUM(sessions) AS DECIMAL(9,2)) AS revenue_per_session_usd,
       CAST(SUM(bounces) * 1.0 / SUM(sessions) AS DECIMAL(9,4)) AS bounce_rate
INTO ads.channel_yearly
FROM dws.session_daily
GROUP BY YEAR(session_date), channel, channel_type;
GO

/* 流量结构：付费拉新 / 付费品牌词 / 免费流量 各占多少（免费流量和品牌词上升 = 品牌知名度在变强） */
SELECT CAST(YEAR(session_date) AS VARCHAR(4)) + 'Q' + CAST(DATEPART(QUARTER, session_date) AS VARCHAR(1)) AS quarter,
       channel_type,
       SUM(sessions) AS sessions,
       CAST(SUM(sessions) * 1.0 / SUM(SUM(sessions)) OVER (PARTITION BY
            CAST(YEAR(session_date) AS VARCHAR(4)) + 'Q' + CAST(DATEPART(QUARTER, session_date) AS VARCHAR(1)))
            AS DECIMAL(9,4)) AS session_share,
       SUM(orders) AS orders,
       CAST(SUM(orders) * 1.0 / SUM(SUM(orders)) OVER (PARTITION BY
            CAST(YEAR(session_date) AS VARCHAR(4)) + 'Q' + CAST(DATEPART(QUARTER, session_date) AS VARCHAR(1)))
            AS DECIMAL(9,4)) AS order_share
INTO ads.channel_type_quarterly
FROM dws.session_daily
GROUP BY CAST(YEAR(session_date) AS VARCHAR(4)) + 'Q' + CAST(DATEPART(QUARTER, session_date) AS VARCHAR(1)),
         channel_type;
GO

/* 付费搜索（非品牌词）分设备：G、B 两个搜索引擎在电脑端和手机端的转化差异，决定出价怎么调 */
SELECT YEAR(session_date) AS year, channel, device_type,
       SUM(sessions) AS sessions, SUM(orders) AS orders,
       CAST(SUM(orders) * 1.0 / SUM(sessions) AS DECIMAL(9,4)) AS cvr,
       CAST(SUM(revenue_usd) / SUM(sessions) AS DECIMAL(9,2)) AS revenue_per_session_usd
INTO ads.paid_search_device
FROM dws.session_daily
WHERE channel IN (N'G搜索-非品牌词', N'B搜索-非品牌词', N'社交广告')
GROUP BY YEAR(session_date), channel, device_type;
GO

/* ---------- Q4 转化漏斗：2014 全年，按设备，看顾客在哪一步流失最多 ---------- */
SELECT device_type,
       SUM(sessions) AS sessions,
       SUM(sessions - bounces) AS not_bounced,
       SUM(to_products) AS to_products, SUM(to_product_detail) AS to_product_detail,
       SUM(to_cart) AS to_cart, SUM(to_shipping) AS to_shipping, SUM(to_billing) AS to_billing,
       SUM(orders) AS orders,
       CAST(SUM(to_products) * 1.0 / SUM(sessions) AS DECIMAL(9,4))        AS rate_landing_to_products,
       CAST(SUM(to_product_detail) * 1.0 / SUM(to_products) AS DECIMAL(9,4)) AS rate_products_to_detail,
       CAST(SUM(to_cart) * 1.0 / SUM(to_product_detail) AS DECIMAL(9,4))   AS rate_detail_to_cart,
       CAST(SUM(to_shipping) * 1.0 / SUM(to_cart) AS DECIMAL(9,4))         AS rate_cart_to_shipping,
       CAST(SUM(to_billing) * 1.0 / SUM(to_shipping) AS DECIMAL(9,4))      AS rate_shipping_to_billing,
       CAST(SUM(orders) * 1.0 / SUM(to_billing) AS DECIMAL(9,4))           AS rate_billing_to_order,
       CAST(SUM(orders) * 1.0 / SUM(sessions) AS DECIMAL(9,4))             AS cvr
INTO ads.funnel_device
FROM dws.session_daily
WHERE session_date >= '2014-01-01' AND session_date < '2015-01-01'
GROUP BY device_type;
GO

/* ---------- Q5 商品：季度销量与收入结构、交叉销售、退款率 ---------- */
SELECT CAST(YEAR(order_month) AS VARCHAR(4)) + 'Q' + CAST(DATEPART(QUARTER, order_month) AS VARCHAR(1)) AS quarter,
       product_id, product_name,
       SUM(items_sold) AS items_sold, SUM(revenue_usd) AS revenue_usd,
       SUM(revenue_usd - cogs_usd) AS gross_profit_usd,
       CAST(SUM(revenue_usd - cogs_usd) / SUM(revenue_usd) AS DECIMAL(9,4)) AS gross_margin,
       CAST(SUM(revenue_usd) / SUM(SUM(revenue_usd)) OVER (PARTITION BY
            CAST(YEAR(order_month) AS VARCHAR(4)) + 'Q' + CAST(DATEPART(QUARTER, order_month) AS VARCHAR(1)))
            AS DECIMAL(9,4)) AS revenue_share
INTO ads.product_quarterly
FROM dws.order_item_monthly
GROUP BY CAST(YEAR(order_month) AS VARCHAR(4)) + 'Q' + CAST(DATEPART(QUARTER, order_month) AS VARCHAR(1)),
         product_id, product_name;
GO

/* 交叉销售：第 4 款商品上架（2014-02-05）后，按主商品看，顾客还会顺带买哪一款 */
WITH o AS (
    SELECT o.order_id, o.primary_product_id, o.items_purchased
    FROM dwd.fact_order o
    WHERE o.ordered_at >= '2014-02-05'
), x AS (
    SELECT o.primary_product_id, i.product_id AS cross_product_id, COUNT(*) AS orders
    FROM o JOIN dwd.fact_order_item i ON i.order_id = o.order_id AND i.is_primary_item = 0
    GROUP BY o.primary_product_id, i.product_id
)
SELECT p.product_id AS primary_product_id, p.product_name AS primary_product,
       t.orders AS primary_orders,
       cp.product_id AS cross_product_id, cp.product_name AS cross_product,
       ISNULL(x.orders, 0) AS cross_orders,
       CAST(ISNULL(x.orders, 0) * 1.0 / t.orders AS DECIMAL(9,4)) AS cross_sell_rate
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
       CAST(SUM(items_refunded) * 1.0 / SUM(items_sold) AS DECIMAL(9,4)) AS refund_rate,
       SUM(refund_amount_usd) AS refund_amount_usd
INTO ads.refund_monthly
FROM dws.order_item_monthly
GROUP BY order_month, product_id, product_name;
GO

/* ---------- Q6 回访顾客：新访客 vs 回访，各自从哪个渠道来、转化如何 ---------- */
SELECT CASE is_repeat_session WHEN 1 THEN N'回访' ELSE N'首次访问' END AS visitor_type,
       channel,
       SUM(sessions) AS sessions,
       CAST(SUM(sessions) * 1.0 / SUM(SUM(sessions)) OVER (PARTITION BY is_repeat_session) AS DECIMAL(9,4)) AS share_within_type,
       SUM(orders) AS orders,
       CAST(SUM(orders) * 1.0 / SUM(sessions) AS DECIMAL(9,4)) AS cvr,
       CAST(SUM(revenue_usd) / SUM(sessions) AS DECIMAL(9,2)) AS revenue_per_session_usd
INTO ads.repeat_visitors
FROM dws.session_daily
WHERE session_date >= '2014-01-01' AND session_date < '2015-01-01'
GROUP BY is_repeat_session, channel;
GO

/* ---------- Q7 时段：2014 年每个“星期几 × 小时”平均有多少次访问（客服排班用） ---------- */
SELECT DATEPART(WEEKDAY, session_start) AS weekday,      -- 1 = 周一
       DATEPART(HOUR, session_start) AS hour,
       COUNT(*) AS sessions,
       CAST(COUNT(*) * 1.0 / COUNT(DISTINCT session_date) AS DECIMAL(9,1)) AS avg_sessions_per_day
INTO ads.traffic_heatmap
FROM dwd.fact_session
WHERE session_start >= '2014-01-01' AND session_start < '2015-01-01'
GROUP BY DATEPART(WEEKDAY, session_start), DATEPART(HOUR, session_start);
GO
