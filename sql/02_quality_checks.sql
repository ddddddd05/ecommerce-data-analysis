/* 02 数据质量检查（在原始层上做，加工前先确认数据可信）
   每条检查记一行到 dq.check_results：问题行数 failed_rows = 0 才算通过。
   严重程度：
     阻断  数据错了会直接算错指标（主键重复、关联不上、金额对不上）→ 流水线停止
     警告  需要在报告里说明，但不影响加工
     信息  记录数据特征（如文字 "NULL" 有多少），供明细层处理
*/
USE [{{DATABASE}}];
GO
IF OBJECT_ID(N'dq.check_results') IS NOT NULL DROP TABLE dq.check_results;
CREATE TABLE dq.check_results (
    check_id     INT IDENTITY(1,1) PRIMARY KEY,
    category     NVARCHAR(20)  NOT NULL,   -- 完整性 / 唯一性 / 格式 / 关联 / 业务规则
    table_name   VARCHAR(50)   NOT NULL,
    check_name   NVARCHAR(200) NOT NULL,
    severity     NVARCHAR(10)  NOT NULL,   -- 阻断 / 警告 / 信息
    failed_rows  INT           NOT NULL,
    checked_at   DATETIME      NOT NULL DEFAULT GETDATE()
);
GO

/* ---------- 唯一性：主键不重复、不为空 ---------- */
INSERT dq.check_results (category, table_name, check_name, severity, failed_rows)
SELECT N'唯一性', 'website_sessions', N'website_session_id 重复或为空', N'阻断',
       COUNT(*) - COUNT(DISTINCT website_session_id) + SUM(CASE WHEN website_session_id IS NULL THEN 1 ELSE 0 END)
FROM ods.website_sessions
UNION ALL
SELECT N'唯一性', 'website_pageviews', N'website_pageview_id 重复或为空', N'阻断',
       COUNT(*) - COUNT(DISTINCT website_pageview_id) + SUM(CASE WHEN website_pageview_id IS NULL THEN 1 ELSE 0 END)
FROM ods.website_pageviews
UNION ALL
SELECT N'唯一性', 'orders', N'order_id 重复或为空', N'阻断',
       COUNT(*) - COUNT(DISTINCT order_id) + SUM(CASE WHEN order_id IS NULL THEN 1 ELSE 0 END)
FROM ods.orders
UNION ALL
SELECT N'唯一性', 'orders', N'一个访问对应多笔订单（website_session_id 重复）', N'阻断',
       COUNT(*) - COUNT(DISTINCT website_session_id)
FROM ods.orders
UNION ALL
SELECT N'唯一性', 'order_items', N'order_item_id 重复或为空', N'阻断',
       COUNT(*) - COUNT(DISTINCT order_item_id) + SUM(CASE WHEN order_item_id IS NULL THEN 1 ELSE 0 END)
FROM ods.order_items
UNION ALL
SELECT N'唯一性', 'order_item_refunds', N'一件商品被退款多次（order_item_id 重复）', N'阻断',
       COUNT(*) - COUNT(DISTINCT order_item_id)
FROM ods.order_item_refunds;

/* ---------- 格式：编号是纯数字、时间能转换、金额是数字 ---------- */
INSERT dq.check_results (category, table_name, check_name, severity, failed_rows)
SELECT N'格式', 'website_sessions', N'编号不是纯数字或时间无法识别', N'阻断', COUNT(*)
FROM ods.website_sessions
WHERE website_session_id LIKE '%[^0-9]%' OR user_id LIKE '%[^0-9]%' OR ISDATE(created_at) = 0
   OR is_repeat_session NOT IN ('0', '1')
UNION ALL
SELECT N'格式', 'website_pageviews', N'编号不是纯数字或时间无法识别', N'阻断', COUNT(*)
FROM ods.website_pageviews
WHERE website_pageview_id LIKE '%[^0-9]%' OR website_session_id LIKE '%[^0-9]%' OR ISDATE(created_at) = 0
UNION ALL
SELECT N'格式', 'orders', N'编号、件数不是纯数字，时间无法识别，或金额不是数字', N'阻断', COUNT(*)
FROM ods.orders
WHERE order_id LIKE '%[^0-9]%' OR website_session_id LIKE '%[^0-9]%' OR items_purchased LIKE '%[^0-9]%'
   OR ISDATE(created_at) = 0 OR price_usd LIKE '%[^0-9.]%' OR cogs_usd LIKE '%[^0-9.]%'
UNION ALL
SELECT N'格式', 'order_items', N'编号不是纯数字，时间无法识别，或金额不是数字', N'阻断', COUNT(*)
FROM ods.order_items
WHERE order_item_id LIKE '%[^0-9]%' OR order_id LIKE '%[^0-9]%' OR product_id LIKE '%[^0-9]%'
   OR is_primary_item NOT IN ('0', '1') OR ISDATE(created_at) = 0
   OR price_usd LIKE '%[^0-9.]%' OR cogs_usd LIKE '%[^0-9.]%'
UNION ALL
SELECT N'格式', 'order_item_refunds', N'编号不是纯数字，时间无法识别，或金额不是数字', N'阻断', COUNT(*)
FROM ods.order_item_refunds
WHERE order_item_id LIKE '%[^0-9]%' OR ISDATE(created_at) = 0 OR refund_amount_usd LIKE '%[^0-9.]%'
UNION ALL
SELECT N'格式', 'website_sessions', N'device_type 不是 mobile/desktop', N'阻断', COUNT(*)
FROM ods.website_sessions WHERE device_type NOT IN ('mobile', 'desktop')
UNION ALL
SELECT N'格式', 'website_sessions', N'渠道字段写成文字 "NULL"（明细层转成空值）', N'信息', COUNT(*)
FROM ods.website_sessions WHERE utm_source = 'NULL' OR http_referer = 'NULL';

/* ---------- 关联：子表的编号在父表里都找得到 ---------- */
INSERT dq.check_results (category, table_name, check_name, severity, failed_rows)
SELECT N'关联', 'website_pageviews', N'浏览记录找不到对应的访问', N'阻断', COUNT(*)
FROM ods.website_pageviews p
WHERE NOT EXISTS (SELECT 1 FROM ods.website_sessions s WHERE s.website_session_id = p.website_session_id)
UNION ALL
SELECT N'关联', 'website_sessions', N'访问没有任何浏览记录（无法确定落地页）', N'警告', COUNT(*)
FROM ods.website_sessions s
WHERE NOT EXISTS (SELECT 1 FROM ods.website_pageviews p WHERE p.website_session_id = s.website_session_id)
UNION ALL
SELECT N'关联', 'orders', N'订单找不到对应的访问', N'阻断', COUNT(*)
FROM ods.orders o
WHERE NOT EXISTS (SELECT 1 FROM ods.website_sessions s WHERE s.website_session_id = o.website_session_id)
UNION ALL
SELECT N'关联', 'orders', N'订单的 user_id 和所属访问的 user_id 不一致', N'阻断', COUNT(*)
FROM ods.orders o JOIN ods.website_sessions s ON s.website_session_id = o.website_session_id
WHERE s.user_id <> o.user_id
UNION ALL
SELECT N'关联', 'order_items', N'订单明细找不到对应的订单', N'阻断', COUNT(*)
FROM ods.order_items i
WHERE NOT EXISTS (SELECT 1 FROM ods.orders o WHERE o.order_id = i.order_id)
UNION ALL
SELECT N'关联', 'order_items', N'订单明细的商品不在商品表里', N'阻断', COUNT(*)
FROM ods.order_items i
WHERE NOT EXISTS (SELECT 1 FROM ods.products p WHERE p.product_id = i.product_id)
UNION ALL
SELECT N'关联', 'order_item_refunds', N'退款找不到对应的订单明细，或订单号对不上', N'阻断', COUNT(*)
FROM ods.order_item_refunds r
WHERE NOT EXISTS (SELECT 1 FROM ods.order_items i
                  WHERE i.order_item_id = r.order_item_id AND i.order_id = r.order_id);

/* ---------- 业务规则：金额、件数、时间先后 ---------- */
INSERT dq.check_results (category, table_name, check_name, severity, failed_rows)
SELECT N'业务规则', 'orders', N'订单金额 ≠ 明细金额之和', N'阻断', COUNT(*)
FROM ods.orders o
JOIN (SELECT order_id, SUM(CAST(price_usd AS DECIMAL(10,2))) AS price
      FROM ods.order_items GROUP BY order_id) i ON i.order_id = o.order_id
WHERE CAST(o.price_usd AS DECIMAL(10,2)) <> i.price
UNION ALL
SELECT N'业务规则', 'orders', N'订单成本 ≠ 明细成本之和', N'阻断', COUNT(*)
FROM ods.orders o
JOIN (SELECT order_id, SUM(CAST(cogs_usd AS DECIMAL(10,2))) AS cogs
      FROM ods.order_items GROUP BY order_id) i ON i.order_id = o.order_id
WHERE CAST(o.cogs_usd AS DECIMAL(10,2)) <> i.cogs
UNION ALL
SELECT N'业务规则', 'orders', N'items_purchased ≠ 明细件数', N'阻断', COUNT(*)
FROM ods.orders o
JOIN (SELECT order_id, COUNT(*) AS n FROM ods.order_items GROUP BY order_id) i ON i.order_id = o.order_id
WHERE CAST(o.items_purchased AS INT) <> i.n
UNION ALL
SELECT N'业务规则', 'order_items', N'订单的主商品不是恰好 1 件', N'阻断', COUNT(*)
FROM (SELECT order_id FROM ods.order_items GROUP BY order_id
      HAVING SUM(CAST(is_primary_item AS INT)) <> 1) x
UNION ALL
SELECT N'业务规则', 'orders', N'primary_product_id 和明细里的主商品不一致', N'阻断', COUNT(*)
FROM ods.orders o JOIN ods.order_items i ON i.order_id = o.order_id AND i.is_primary_item = '1'
WHERE i.product_id <> o.primary_product_id
UNION ALL
SELECT N'业务规则', 'order_items', N'售价 ≤ 成本（亏本卖）', N'警告', COUNT(*)
FROM ods.order_items WHERE CAST(price_usd AS DECIMAL(10,2)) <= CAST(cogs_usd AS DECIMAL(10,2))
UNION ALL
SELECT N'业务规则', 'order_item_refunds', N'退款金额超过商品售价', N'阻断', COUNT(*)
FROM ods.order_item_refunds r JOIN ods.order_items i ON i.order_item_id = r.order_item_id
WHERE CAST(r.refund_amount_usd AS DECIMAL(10,2)) > CAST(i.price_usd AS DECIMAL(10,2))
UNION ALL
SELECT N'业务规则', 'order_item_refunds', N'部分退款（退款金额小于售价）', N'信息', COUNT(*)
FROM ods.order_item_refunds r JOIN ods.order_items i ON i.order_item_id = r.order_item_id
WHERE CAST(r.refund_amount_usd AS DECIMAL(10,2)) < CAST(i.price_usd AS DECIMAL(10,2))
UNION ALL
SELECT N'业务规则', 'order_item_refunds', N'退款时间早于下单时间', N'阻断', COUNT(*)
FROM ods.order_item_refunds r JOIN ods.order_items i ON i.order_item_id = r.order_item_id
WHERE CAST(r.created_at AS DATETIME) < CAST(i.created_at AS DATETIME)
UNION ALL
SELECT N'业务规则', 'orders', N'下单时间早于访问开始时间', N'阻断', COUNT(*)
FROM ods.orders o JOIN ods.website_sessions s ON s.website_session_id = o.website_session_id
WHERE CAST(o.created_at AS DATETIME) < CAST(s.created_at AS DATETIME)
UNION ALL
SELECT N'业务规则', 'order_items', N'商品在上架之前就被卖出', N'阻断', COUNT(*)
FROM ods.order_items i JOIN ods.products p ON p.product_id = i.product_id
WHERE CAST(i.created_at AS DATETIME) < CAST(p.created_at AS DATETIME)
UNION ALL
SELECT N'业务规则', 'orders', N'下了单但访问里没有“感谢下单”页面', N'警告', COUNT(*)
FROM ods.orders o
WHERE NOT EXISTS (SELECT 1 FROM ods.website_pageviews p
                  WHERE p.website_session_id = o.website_session_id
                    AND p.pageview_url = '/thank-you-for-your-order')
UNION ALL
SELECT N'业务规则', 'website_pageviews', N'有“感谢下单”页面但没有订单', N'警告', COUNT(*)
FROM ods.website_pageviews p
WHERE p.pageview_url = '/thank-you-for-your-order'
  AND NOT EXISTS (SELECT 1 FROM ods.orders o WHERE o.website_session_id = p.website_session_id)
UNION ALL
SELECT N'业务规则', 'website_sessions', N'is_repeat_session = 0 但该用户之前已经访问过', N'警告', COUNT(*)
FROM ods.website_sessions s
WHERE s.is_repeat_session = '0'
  AND EXISTS (SELECT 1 FROM ods.website_sessions s2
              WHERE s2.user_id = s.user_id
                AND CAST(s2.website_session_id AS INT) < CAST(s.website_session_id AS INT))
UNION ALL
SELECT N'业务规则', 'website_sessions', N'utm_campaign 有值但 utm_source 为空（渠道标记不完整）', N'警告', COUNT(*)
FROM ods.website_sessions WHERE utm_source = 'NULL' AND utm_campaign <> 'NULL'
UNION ALL
SELECT N'业务规则', 'website_pageviews', N'浏览时间早于所属访问的开始时间', N'阻断', COUNT(*)
FROM ods.website_pageviews p JOIN ods.website_sessions s ON s.website_session_id = p.website_session_id
WHERE CAST(p.created_at AS DATETIME) < CAST(s.created_at AS DATETIME)
UNION ALL
SELECT N'完整性', 'website_sessions', N'最后一个月数据不完整（只到 ' +
       CONVERT(NVARCHAR(10), m.last_at, 120) + N'），月度对比时要剔除', N'信息',
       SUM(CASE WHEN CAST(s.created_at AS DATETIME) >= DATEADD(MONTH, DATEDIFF(MONTH, 0, m.last_at), 0)
                THEN 1 ELSE 0 END)
FROM ods.website_sessions s
CROSS JOIN (SELECT MAX(CAST(created_at AS DATETIME)) AS last_at FROM ods.website_sessions) m
GROUP BY m.last_at;
GO
