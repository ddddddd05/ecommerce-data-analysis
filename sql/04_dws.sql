/* 04 汇总层（dws）：按常用维度预先汇总，应用层和看板都从这里取数，避免每次扫 47 万行访问明细。
   口径和明细层完全一致（只是加总），层间核对见本文件末尾。
*/
USE [{{DATABASE}}];
GO
IF OBJECT_ID(N'dws.session_daily')      IS NOT NULL DROP TABLE dws.session_daily;
IF OBJECT_ID(N'dws.order_item_monthly') IS NOT NULL DROP TABLE dws.order_item_monthly;
GO

/* 访问日汇总：日期 × 渠道 × 设备 × 新老访客 × 落地页 */
SELECT session_date,
       session_month,
       channel, channel_type, device_type,
       CAST(is_repeat_session AS INT)  AS is_repeat_session,
       landing_page,
       COUNT(*)                        AS sessions,
       SUM(is_bounce)                  AS bounces,
       SUM(reached_products)           AS to_products,
       SUM(reached_product_detail)     AS to_product_detail,
       SUM(reached_cart)               AS to_cart,
       SUM(reached_shipping)           AS to_shipping,
       SUM(reached_billing)            AS to_billing,
       SUM(has_order)                  AS orders,
       SUM(revenue_usd)                AS revenue_usd,
       SUM(gross_profit_usd)           AS gross_profit_usd
INTO dws.session_daily
FROM dwd.fact_session
GROUP BY session_date, session_month, channel, channel_type, device_type, is_repeat_session, landing_page;
CREATE INDEX ix_session_daily ON dws.session_daily (session_date, channel);
GO

/* 商品月汇总：按订单月份统计每个商品的销量、收入、成本、退款（退款算回到下单月份，便于看“这批货”的质量） */
SELECT DATEADD(MONTH, DATEDIFF(MONTH, 0, i.ordered_at), 0) AS order_month,
       i.product_id,
       p.product_name,
       CAST(i.is_primary_item AS INT)  AS is_primary_item,
       COUNT(*)                        AS items_sold,
       SUM(i.price_usd)                AS revenue_usd,
       SUM(i.cogs_usd)                 AS cogs_usd,
       SUM(i.is_refunded)              AS items_refunded,
       SUM(i.refund_amount_usd)        AS refund_amount_usd
INTO dws.order_item_monthly
FROM dwd.fact_order_item i
JOIN dwd.dim_product p ON p.product_id = i.product_id
GROUP BY DATEADD(MONTH, DATEDIFF(MONTH, 0, i.ordered_at), 0), i.product_id, p.product_name,
         CAST(i.is_primary_item AS INT);
GO

INSERT dq.check_results (category, table_name, check_name, severity, failed_rows)
SELECT N'层间核对', 'dws.session_daily', N'汇总后的访问数、订单数、收入和明细层不一致', N'阻断',
       CASE WHEN (SELECT SUM(sessions) FROM dws.session_daily) = (SELECT COUNT(*) FROM dwd.fact_session)
             AND (SELECT SUM(orders) FROM dws.session_daily) = (SELECT COUNT(*) FROM dwd.fact_order)
             AND (SELECT SUM(revenue_usd) FROM dws.session_daily) = (SELECT SUM(revenue_usd) FROM dwd.fact_order)
            THEN 0 ELSE 1 END
UNION ALL
SELECT N'层间核对', 'dws.order_item_monthly', N'汇总后的销量、收入、退款和明细层不一致', N'阻断',
       CASE WHEN (SELECT SUM(items_sold) FROM dws.order_item_monthly) = (SELECT COUNT(*) FROM dwd.fact_order_item)
             AND (SELECT SUM(revenue_usd) FROM dws.order_item_monthly) = (SELECT SUM(revenue_usd) FROM dwd.fact_order)
             AND (SELECT SUM(refund_amount_usd) FROM dws.order_item_monthly)
               = (SELECT SUM(refund_amount_usd) FROM dwd.fact_order)
            THEN 0 ELSE 1 END;
GO
