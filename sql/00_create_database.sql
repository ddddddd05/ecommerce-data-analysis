/* 00 建库和分层（schema）
   分层的意思：同一个数据库里按“加工程度”分成几个区，每一层只读上一层：
     ods  原始层（Operational Data Store）：原样落地，全部存成文字，不改任何值，出问题可以追溯
     dwd  明细层（Data Warehouse Detail）：类型转换、空值处理、派生字段（落地页、渠道、是否下单）
     dws  汇总层（Data Warehouse Summary）：按天/月/渠道等常用维度预先汇总，多处复用
     ads  应用层（Application Data Service）：直接回答业务问题的结果表，报告和看板只读这一层
     dq   数据质量（Data Quality）：导入记录和质量检查结果
   脚本可以重复运行：已存在就跳过。
*/
IF DB_ID(N'{{DATABASE}}') IS NULL
    EXEC(N'CREATE DATABASE [{{DATABASE}}]');
GO
USE [{{DATABASE}}];
GO
IF SCHEMA_ID(N'ods') IS NULL EXEC(N'CREATE SCHEMA ods');
IF SCHEMA_ID(N'dwd') IS NULL EXEC(N'CREATE SCHEMA dwd');
IF SCHEMA_ID(N'dws') IS NULL EXEC(N'CREATE SCHEMA dws');
IF SCHEMA_ID(N'ads') IS NULL EXEC(N'CREATE SCHEMA ads');
IF SCHEMA_ID(N'dq')  IS NULL EXEC(N'CREATE SCHEMA dq');
GO
IF OBJECT_ID(N'dq.load_log') IS NULL
    CREATE TABLE dq.load_log (
        load_id     INT IDENTITY(1,1) PRIMARY KEY,
        table_name  VARCHAR(50)  NOT NULL,
        file_rows   INT          NOT NULL,   -- 文件里的行数（prepare_staging.py 统计）
        loaded_rows INT          NOT NULL,   -- 实际导入的行数
        loaded_at   DATETIME     NOT NULL DEFAULT GETDATE()
    );
GO
