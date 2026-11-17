/* 01 原始层：建表 + 导入
   所有字段都用 NVARCHAR 原样存储（包括文件里写成文字 "NULL" 的值），类型转换和空值处理留给明细层。
   这样原始层永远和源文件一致：明细层的规则改错了，可以从原始层重新加工，不用重新找源文件。
   {{STAGING}} 由 pipeline/run_pipeline.py 替换成 data/staging 的绝对路径。
   文件是 UTF-16 编码（DATAFILETYPE = 'widechar'，支持中文等非 ASCII 字符），
   行尾是回车换行（ROWTERMINATOR = '\n' 在 SQL Server 里表示回车换行）。
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
    website_session_id NVARCHAR(20), created_at NVARCHAR(30), user_id NVARCHAR(20),
    is_repeat_session NVARCHAR(10), utm_source NVARCHAR(50), utm_campaign NVARCHAR(50),
    utm_content NVARCHAR(50), device_type NVARCHAR(20), http_referer NVARCHAR(200));
CREATE TABLE ods.website_pageviews (
    website_pageview_id NVARCHAR(20), created_at NVARCHAR(30), website_session_id NVARCHAR(20),
    pageview_url NVARCHAR(200));
CREATE TABLE ods.orders (
    order_id NVARCHAR(20), created_at NVARCHAR(30), website_session_id NVARCHAR(20), user_id NVARCHAR(20),
    primary_product_id NVARCHAR(20), items_purchased NVARCHAR(10), price_usd NVARCHAR(20), cogs_usd NVARCHAR(20));
CREATE TABLE ods.order_items (
    order_item_id NVARCHAR(20), created_at NVARCHAR(30), order_id NVARCHAR(20), product_id NVARCHAR(20),
    is_primary_item NVARCHAR(10), price_usd NVARCHAR(20), cogs_usd NVARCHAR(20));
CREATE TABLE ods.order_item_refunds (
    order_item_refund_id NVARCHAR(20), created_at NVARCHAR(30), order_item_id NVARCHAR(20),
    order_id NVARCHAR(20), refund_amount_usd NVARCHAR(20));
CREATE TABLE ods.products (
    product_id NVARCHAR(20), created_at NVARCHAR(30), product_name NVARCHAR(100));
GO
BULK INSERT ods.website_sessions   FROM '{{STAGING}}\website_sessions.tsv'
    WITH (FIRSTROW = 2, DATAFILETYPE = 'widechar', FIELDTERMINATOR = '\t', ROWTERMINATOR = '\n', TABLOCK);
BULK INSERT ods.website_pageviews  FROM '{{STAGING}}\website_pageviews.tsv'
    WITH (FIRSTROW = 2, DATAFILETYPE = 'widechar', FIELDTERMINATOR = '\t', ROWTERMINATOR = '\n', TABLOCK);
BULK INSERT ods.orders             FROM '{{STAGING}}\orders.tsv'
    WITH (FIRSTROW = 2, DATAFILETYPE = 'widechar', FIELDTERMINATOR = '\t', ROWTERMINATOR = '\n', TABLOCK);
BULK INSERT ods.order_items        FROM '{{STAGING}}\order_items.tsv'
    WITH (FIRSTROW = 2, DATAFILETYPE = 'widechar', FIELDTERMINATOR = '\t', ROWTERMINATOR = '\n', TABLOCK);
BULK INSERT ods.order_item_refunds FROM '{{STAGING}}\order_item_refunds.tsv'
    WITH (FIRSTROW = 2, DATAFILETYPE = 'widechar', FIELDTERMINATOR = '\t', ROWTERMINATOR = '\n', TABLOCK);
BULK INSERT ods.products           FROM '{{STAGING}}\products.tsv'
    WITH (FIRSTROW = 2, DATAFILETYPE = 'widechar', FIELDTERMINATOR = '\t', ROWTERMINATOR = '\n', TABLOCK);
GO
/* 刚导入的表还没有统计信息，优化器会按错误的行数选执行计划，
   下一步质量检查曾因此从约 30 秒变成 200 秒。导入后立即更新统计信息。 */
UPDATE STATISTICS ods.website_sessions   WITH FULLSCAN;
UPDATE STATISTICS ods.website_pageviews  WITH FULLSCAN;
UPDATE STATISTICS ods.orders             WITH FULLSCAN;
UPDATE STATISTICS ods.order_items        WITH FULLSCAN;
UPDATE STATISTICS ods.order_item_refunds WITH FULLSCAN;
UPDATE STATISTICS ods.products           WITH FULLSCAN;
GO
