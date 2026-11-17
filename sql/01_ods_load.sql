/* 01 原始层：建表 + 导入
   所有字段都用 VARCHAR 原样存储（包括文件里写成文字 "NULL" 的值），类型转换和空值处理留给明细层。
   这样原始层永远和源文件一致：明细层的规则改错了，可以从原始层重新加工，不用重新找源文件。
   {{STAGING}} 由 pipeline/run_pipeline.py 替换成 data/staging 的绝对路径。
*/
USE [{{DATABASE}}];
GO
IF OBJECT_ID(N'ods.website_sessions')   IS NOT NULL DROP TABLE ods.website_sessions;
IF OBJECT_ID(N'ods.website_pageviews')  IS NOT NULL DROP TABLE ods.website_pageviews;
IF OBJECT_ID(N'ods.orders')             IS NOT NULL DROP TABLE ods.orders;
IF OBJECT_ID(N'ods.order_items')        IS NOT NULL DROP TABLE ods.order_items;
IF OBJECT_ID(N'ods.order_item_refunds') IS NOT NULL DROP TABLE ods.order_item_refunds;
IF OBJECT_ID(N'ods.products')           IS NOT NULL DROP TABLE ods.products;
GO
CREATE TABLE ods.website_sessions (
    website_session_id VARCHAR(20), created_at VARCHAR(30), user_id VARCHAR(20),
    is_repeat_session VARCHAR(10), utm_source VARCHAR(50), utm_campaign VARCHAR(50),
    utm_content VARCHAR(50), device_type VARCHAR(20), http_referer VARCHAR(200));
CREATE TABLE ods.website_pageviews (
    website_pageview_id VARCHAR(20), created_at VARCHAR(30), website_session_id VARCHAR(20),
    pageview_url VARCHAR(200));
CREATE TABLE ods.orders (
    order_id VARCHAR(20), created_at VARCHAR(30), website_session_id VARCHAR(20), user_id VARCHAR(20),
    primary_product_id VARCHAR(20), items_purchased VARCHAR(10), price_usd VARCHAR(20), cogs_usd VARCHAR(20));
CREATE TABLE ods.order_items (
    order_item_id VARCHAR(20), created_at VARCHAR(30), order_id VARCHAR(20), product_id VARCHAR(20),
    is_primary_item VARCHAR(10), price_usd VARCHAR(20), cogs_usd VARCHAR(20));
CREATE TABLE ods.order_item_refunds (
    order_item_refund_id VARCHAR(20), created_at VARCHAR(30), order_item_id VARCHAR(20),
    order_id VARCHAR(20), refund_amount_usd VARCHAR(20));
CREATE TABLE ods.products (
    product_id VARCHAR(20), created_at VARCHAR(30), product_name VARCHAR(100));
GO
BULK INSERT ods.website_sessions   FROM '{{STAGING}}\website_sessions.tsv'
    WITH (FIRSTROW = 2, FIELDTERMINATOR = '\t', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT ods.website_pageviews  FROM '{{STAGING}}\website_pageviews.tsv'
    WITH (FIRSTROW = 2, FIELDTERMINATOR = '\t', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT ods.orders             FROM '{{STAGING}}\orders.tsv'
    WITH (FIRSTROW = 2, FIELDTERMINATOR = '\t', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT ods.order_items        FROM '{{STAGING}}\order_items.tsv'
    WITH (FIRSTROW = 2, FIELDTERMINATOR = '\t', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT ods.order_item_refunds FROM '{{STAGING}}\order_item_refunds.tsv'
    WITH (FIRSTROW = 2, FIELDTERMINATOR = '\t', ROWTERMINATOR = '0x0a', TABLOCK);
BULK INSERT ods.products           FROM '{{STAGING}}\products.tsv'
    WITH (FIRSTROW = 2, FIELDTERMINATOR = '\t', ROWTERMINATOR = '0x0a', TABLOCK);
GO
