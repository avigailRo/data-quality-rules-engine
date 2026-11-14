/* 01 - Create database and schemas (idempotent: drops and recreates the demo DB) */
USE master;
GO
IF DB_ID(N'DataControls') IS NOT NULL
BEGIN
    ALTER DATABASE DataControls SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DataControls;
END
GO
CREATE DATABASE DataControls COLLATE Hebrew_100_CI_AS;
GO
USE DataControls;
GO
EXEC (N'CREATE SCHEMA biz AUTHORIZATION dbo;');  -- business data (read by rules)
GO
EXEC (N'CREATE SCHEMA dq AUTHORIZATION dbo;');   -- system data (catalog, rules, runs)
GO
