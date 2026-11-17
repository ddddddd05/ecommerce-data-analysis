/* 03 明细层（dwd）：一行仍然是一条明细，但类型正确、空值干净，并加上分析要用的派生字段。
   规则写在这里一处，后面所有汇总都用同一个口径（口径说明见 docs/02_指标口径.md）。
*/
USE [{{DATABASE}}];
GO
IF OBJECT_ID(N'dwd.fact_session')    IS NOT NULL DROP TABLE dwd.fact_session;
IF OBJECT_ID(N'dwd.fact_pageview')   IS NOT NULL DROP TABLE dwd.fact_pageview;
IF OBJECT_ID(N'dwd.fact_order_item') IS NOT NULL DROP TABLE dwd.fact_order_item;
IF OBJECT_ID(N'dwd.fact_order')      IS NOT NULL DROP TABLE dwd.fact_order;
IF OBJECT_ID(N'dwd.dim_product')     IS NOT NULL DROP TABLE dwd.dim_product;
GO

/* ---------- 商品维度 ---------- */
SELECT ISNULL(CAST(product_id AS INT), 0) AS product_id,   -- ISNULL：让 SELECT INTO 建出 NOT NULL 列，才能加主键
       product_name,
       CAST(created_at AS DATETIME) AS launched_at
INTO dwd.dim_product
FROM ods.products;
ALTER TABLE dwd.dim_product ADD CONSTRAINT pk_dim_product PRIMARY KEY (product_id);
GO

/* ---------- 浏览明细：加上“第几个页面”和页面类型 ---------- */
SELECT ISNULL(CAST(website_pageview_id AS INT), 0) AS pageview_id,
       CAST(website_session_id AS INT)  AS session_id,
       CAST(created_at AS DATETIME)     AS viewed_at,
       pageview_url,
       ROW_NUMBER() OVER (PARTITION BY CAST(website_session_id AS INT)
                          ORDER BY CAST(website_pageview_id AS INT)) AS page_seq,
       CASE
           WHEN pageview_url = '/home' OR pageview_url LIKE '/lander-%' THEN N'落地页'
           WHEN pageview_url = '/products'                              THEN N'商品列表'
           WHEN pageview_url IN ('/the-original-mr-fuzzy', '/the-forever-love-bear',
                                 '/the-birthday-sugar-panda', '/the-hudson-river-mini-bear') THEN N'商品详情'
           WHEN pageview_url = '/cart'                                  THEN N'购物车'
           WHEN pageview_url = '/shipping'                              THEN N'填写配送'
           WHEN pageview_url LIKE '/billing%'                           THEN N'填写支付'
           WHEN pageview_url = '/thank-you-for-your-order'              THEN N'下单成功'
           ELSE N'其他'
       END AS page_type
INTO dwd.fact_pageview
FROM ods.website_pageviews;
ALTER TABLE dwd.fact_pageview ADD CONSTRAINT pk_fact_pageview PRIMARY KEY (pageview_id);
CREATE INDEX ix_pageview_session ON dwd.fact_pageview (session_id, page_seq);
GO

/* ---------- 订单明细：加上退款信息 ---------- */
SELECT ISNULL(CAST(i.order_item_id AS INT), 0) AS order_item_id,
       CAST(i.order_id AS INT)               AS order_id,
       CAST(i.product_id AS INT)             AS product_id,
       CAST(i.is_primary_item AS BIT)        AS is_primary_item,
       CAST(i.created_at AS DATETIME)        AS ordered_at,
       CAST(i.price_usd AS DECIMAL(10,2))    AS price_usd,
       CAST(i.cogs_usd AS DECIMAL(10,2))     AS cogs_usd,
       CASE WHEN r.order_item_id IS NULL THEN 0 ELSE 1 END AS is_refunded,
       ISNULL(CAST(r.refund_amount_usd AS DECIMAL(10,2)), 0) AS refund_amount_usd,
       CAST(r.created_at AS DATETIME)        AS refunded_at
INTO dwd.fact_order_item
FROM ods.order_items i
LEFT JOIN ods.order_item_refunds r ON r.order_item_id = i.order_item_id;
ALTER TABLE dwd.fact_order_item ADD CONSTRAINT pk_fact_order_item PRIMARY KEY (order_item_id);
CREATE INDEX ix_item_order ON dwd.fact_order_item (order_id);
GO

/* ---------- 订单：金额、毛利、退款汇总到订单 ---------- */
SELECT ISNULL(CAST(o.order_id AS INT), 0)    AS order_id,
       CAST(o.website_session_id AS INT)     AS session_id,
       CAST(o.user_id AS INT)                AS user_id,
       CAST(o.created_at AS DATETIME)        AS ordered_at,
       CAST(CAST(o.created_at AS DATETIME) AS DATE) AS order_date,
       DATEADD(MONTH, DATEDIFF(MONTH, 0, CAST(o.created_at AS DATETIME)), 0) AS order_month,
       CAST(o.primary_product_id AS INT)     AS primary_product_id,
       CAST(o.items_purchased AS INT)        AS items_purchased,
       CAST(o.price_usd AS DECIMAL(10,2))    AS revenue_usd,
       CAST(o.cogs_usd AS DECIMAL(10,2))     AS cogs_usd,
       CAST(o.price_usd AS DECIMAL(10,2)) - CAST(o.cogs_usd AS DECIMAL(10,2)) AS gross_profit_usd,
       ISNULL(r.refunded_items, 0)           AS refunded_items,
       ISNULL(r.refund_amount_usd, 0)        AS refund_amount_usd
INTO dwd.fact_order
FROM ods.orders o
LEFT JOIN (SELECT order_id, SUM(is_refunded) AS refunded_items, SUM(refund_amount_usd) AS refund_amount_usd
           FROM dwd.fact_order_item GROUP BY order_id) r ON r.order_id = CAST(o.order_id AS INT);
ALTER TABLE dwd.fact_order ADD CONSTRAINT pk_fact_order PRIMARY KEY (order_id);
CREATE UNIQUE INDEX ux_order_session ON dwd.fact_order (session_id);
GO

/* ---------- 访问：渠道、落地页、漏斗走到哪一步、是否下单 ----------
   渠道分组规则（docs/02_指标口径.md 第 3 节）：
     有 utm_source                 → 付费渠道，按 utm_source + utm_campaign 细分
     没有 utm_source、有 referer   → 自然搜索（从搜索引擎的普通结果点进来，没花广告费）
     都没有                         → 直接访问（直接输入网址或收藏夹）
*/
WITH s AS (
    SELECT ISNULL(CAST(website_session_id AS INT), 0) AS session_id,
           CAST(user_id AS INT)            AS user_id,
           CAST(created_at AS DATETIME)    AS session_start,
           CAST(is_repeat_session AS BIT)  AS is_repeat_session,
           NULLIF(utm_source, 'NULL')      AS utm_source,
           NULLIF(utm_campaign, 'NULL')    AS utm_campaign,
           NULLIF(utm_content, 'NULL')     AS utm_content,
           device_type,
           NULLIF(http_referer, 'NULL')    AS http_referer
    FROM ods.website_sessions
),
pv AS (
    SELECT session_id,
           COUNT(*) AS pageviews,
           MAX(CASE WHEN page_seq = 1 THEN pageview_url END)            AS landing_page,
           MAX(CASE WHEN page_type = N'商品列表' THEN 1 ELSE 0 END)      AS reached_products,
           MAX(CASE WHEN page_type = N'商品详情' THEN 1 ELSE 0 END)      AS reached_product_detail,
           MAX(CASE WHEN page_type = N'购物车'   THEN 1 ELSE 0 END)      AS reached_cart,
           MAX(CASE WHEN page_type = N'填写配送' THEN 1 ELSE 0 END)      AS reached_shipping,
           MAX(CASE WHEN page_type = N'填写支付' THEN 1 ELSE 0 END)      AS reached_billing,
           MAX(CASE WHEN page_type = N'下单成功' THEN 1 ELSE 0 END)      AS reached_thank_you,
           SUM(CASE WHEN page_type = N'商品详情' THEN 1 ELSE 0 END)      AS product_detail_views
    FROM dwd.fact_pageview
    GROUP BY session_id
),
/* 同一访问可能看了多个商品页 / 支付页：按浏览顺序取“第一个”，口径明确（用 MAX 会按字母顺序取，没有业务含义） */
first_pages AS (
    SELECT session_id,
           MAX(CASE WHEN page_type = N'商品详情' AND rn = 1 THEN pageview_url END) AS first_product_page,
           MAX(CASE WHEN page_type = N'填写支付' AND rn = 1 THEN pageview_url END) AS billing_page
    FROM (SELECT session_id, page_type, pageview_url,
                 ROW_NUMBER() OVER (PARTITION BY session_id, page_type ORDER BY page_seq) AS rn
          FROM dwd.fact_pageview
          WHERE page_type IN (N'商品详情', N'填写支付')) t
    GROUP BY session_id
)
SELECT s.session_id, s.user_id, s.session_start,
       CAST(s.session_start AS DATE) AS session_date,
       DATEADD(MONTH, DATEDIFF(MONTH, 0, s.session_start), 0) AS session_month,
       s.is_repeat_session, s.utm_source, s.utm_campaign, s.utm_content, s.device_type, s.http_referer,
       CASE
           WHEN s.utm_source = 'gsearch' AND s.utm_campaign = 'nonbrand' THEN N'G搜索-非品牌词'
           WHEN s.utm_source = 'gsearch' AND s.utm_campaign = 'brand'    THEN N'G搜索-品牌词'
           WHEN s.utm_source = 'bsearch' AND s.utm_campaign = 'nonbrand' THEN N'B搜索-非品牌词'
           WHEN s.utm_source = 'bsearch' AND s.utm_campaign = 'brand'    THEN N'B搜索-品牌词'
           WHEN s.utm_source = 'socialbook'                              THEN N'社交广告'
           WHEN s.utm_source IS NULL AND s.http_referer IS NOT NULL      THEN N'自然搜索'
           WHEN s.utm_source IS NULL AND s.http_referer IS NULL          THEN N'直接访问'
           ELSE N'其他'
       END AS channel,
       CASE
           WHEN s.utm_campaign = 'nonbrand' OR s.utm_source = 'socialbook' THEN N'付费拉新'
           WHEN s.utm_campaign = 'brand'                                   THEN N'付费品牌词'
           ELSE N'免费流量'
       END AS channel_type,
       pv.pageviews, pv.landing_page,
       CASE WHEN pv.pageviews = 1 THEN 1 ELSE 0 END AS is_bounce,
       pv.reached_products, pv.reached_product_detail, pv.reached_cart,
       pv.reached_shipping, pv.reached_billing, pv.reached_thank_you,
       pv.product_detail_views, fp.first_product_page, fp.billing_page,
       CASE WHEN o.order_id IS NULL THEN 0 ELSE 1 END AS has_order,
       o.order_id,
       ISNULL(o.revenue_usd, 0)      AS revenue_usd,
       ISNULL(o.gross_profit_usd, 0) AS gross_profit_usd
INTO dwd.fact_session
FROM s
JOIN pv ON pv.session_id = s.session_id
LEFT JOIN first_pages fp ON fp.session_id = s.session_id
LEFT JOIN dwd.fact_order o ON o.session_id = s.session_id;
ALTER TABLE dwd.fact_session ADD CONSTRAINT pk_fact_session PRIMARY KEY (session_id);
CREATE INDEX ix_session_month ON dwd.fact_session (session_month, channel);
CREATE INDEX ix_session_landing ON dwd.fact_session (landing_page, session_start);
GO

/* ---------- 加工后核对：明细层和原始层对得上（对不上说明加工规则有误）---------- */
INSERT dq.check_results (category, table_name, check_name, severity, failed_rows)
SELECT N'层间核对', 'dwd.fact_session', N'访问数和原始层不一致', N'阻断',
       ABS((SELECT COUNT(*) FROM dwd.fact_session) - (SELECT COUNT(*) FROM ods.website_sessions))
UNION ALL
SELECT N'层间核对', 'dwd.fact_order', N'订单数或总金额和原始层不一致', N'阻断',
       CASE WHEN (SELECT COUNT(*) FROM dwd.fact_order) = (SELECT COUNT(*) FROM ods.orders)
             AND (SELECT SUM(revenue_usd) FROM dwd.fact_order)
               = (SELECT SUM(CAST(price_usd AS DECIMAL(12,2))) FROM ods.orders) THEN 0 ELSE 1 END
UNION ALL
SELECT N'层间核对', 'dwd.fact_session', N'下单访问数 ≠ 订单数', N'阻断',
       ABS((SELECT SUM(has_order) FROM dwd.fact_session) - (SELECT COUNT(*) FROM dwd.fact_order))
UNION ALL
SELECT N'层间核对', 'dwd.fact_order_item', N'退款总额和原始层不一致', N'阻断',
       CASE WHEN (SELECT SUM(refund_amount_usd) FROM dwd.fact_order_item)
               = (SELECT SUM(CAST(refund_amount_usd AS DECIMAL(12,2))) FROM ods.order_item_refunds)
            THEN 0 ELSE 1 END
UNION ALL
SELECT N'层间核对', 'dwd.fact_session', N'渠道被归到“其他”（分组规则没覆盖到）', N'阻断', COUNT(*)
FROM dwd.fact_session WHERE channel = N'其他'
UNION ALL
SELECT N'层间核对', 'dwd.fact_pageview', N'页面类型被归到“其他”（页面规则没覆盖到）', N'阻断', COUNT(*)
FROM dwd.fact_pageview WHERE page_type = N'其他';
GO
