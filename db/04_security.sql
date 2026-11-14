/* 04 - Least-privilege database principals.

   The demo runs on SQL Server Express with Windows authentication, so instead of SQL logins we
   create database users WITHOUT LOGIN and the application switches to them with
   EXECUTE AS USER for the specific operations:

   - dc_rule_reader : executes compiled control queries. SELECT on schema biz ONLY.
                      No access to dq, no DML/DDL/EXECUTE. Even a bug in the compiler cannot
                      modify data or read rule definitions.
   - dc_profiler    : used by the Python AI service for statistics. SELECT on biz + VIEW DEFINITION.

   In production these would be real logins (or managed identities on GCP) and the API itself
   would connect as a dc_app login with rights on dq only. */
USE DataControls;
GO
CREATE USER dc_rule_reader WITHOUT LOGIN;
CREATE USER dc_profiler    WITHOUT LOGIN;
GO
GRANT SELECT ON SCHEMA::biz TO dc_rule_reader;
DENY  SELECT, INSERT, UPDATE, DELETE, EXECUTE, ALTER ON SCHEMA::dq TO dc_rule_reader;
DENY  INSERT, UPDATE, DELETE, EXECUTE, ALTER ON SCHEMA::biz TO dc_rule_reader;

GRANT SELECT ON SCHEMA::biz TO dc_profiler;
GRANT VIEW DEFINITION ON SCHEMA::biz TO dc_profiler;
DENY  SELECT, INSERT, UPDATE, DELETE, EXECUTE, ALTER ON SCHEMA::dq TO dc_profiler;
DENY  INSERT, UPDATE, DELETE, EXECUTE, ALTER ON SCHEMA::biz TO dc_profiler;
GO
