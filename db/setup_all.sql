/* Full demo setup - generated from 01..07. Run in SSMS (F5). */
/* ===== 01_create_database.sql ===== */
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
GO

/* ===== 02_biz_schema.sql ===== */
/* 02 - Business schema. Deliberately few CHECK constraints so that invalid data can exist
   (that is exactly what the data-quality controls are meant to find). */
USE DataControls;
GO
CREATE TABLE biz.Departments (
    Id                 INT           NOT NULL CONSTRAINT PK_Departments PRIMARY KEY,
    Name               NVARCHAR(100) NOT NULL,
    IsActive           BIT           NOT NULL,
    CostCenter         NVARCHAR(20)  NULL,
    ManagerEmployeeId  INT           NULL
);

CREATE TABLE biz.Positions (
    Id         INT           NOT NULL CONSTRAINT PK_Positions PRIMARY KEY,
    Title      NVARCHAR(100) NOT NULL,
    MinSalary  DECIMAL(12,2) NOT NULL,
    MaxSalary  DECIMAL(12,2) NOT NULL
);

CREATE TABLE biz.Employees (
    Id               INT           NOT NULL CONSTRAINT PK_Employees PRIMARY KEY,
    EmployeeNumber   NVARCHAR(20)  NOT NULL CONSTRAINT UQ_Employees_Number UNIQUE,
    FirstName        NVARCHAR(50)  NOT NULL,
    LastName         NVARCHAR(50)  NOT NULL,
    BirthDate        DATE          NULL,
    HireDate         DATE          NOT NULL,
    TerminationDate  DATE          NULL,
    Salary           DECIMAL(12,2) NOT NULL,
    Status           NVARCHAR(1)   NOT NULL,      -- A = active, T = terminated
    Email            NVARCHAR(200) NULL,
    Phone            NVARCHAR(30)  NULL,
    DepartmentId     INT           NULL CONSTRAINT FK_Employees_Departments REFERENCES biz.Departments(Id),
    PositionId       INT           NOT NULL CONSTRAINT FK_Employees_Positions REFERENCES biz.Positions(Id),
    ManagerId        INT           NULL CONSTRAINT FK_Employees_Manager REFERENCES biz.Employees(Id)
);

ALTER TABLE biz.Departments ADD CONSTRAINT FK_Departments_Manager
    FOREIGN KEY (ManagerEmployeeId) REFERENCES biz.Employees(Id);

CREATE TABLE biz.Projects (
    Id         INT           NOT NULL CONSTRAINT PK_Projects PRIMARY KEY,
    Name       NVARCHAR(100) NOT NULL,
    StartDate  DATE          NOT NULL,
    EndDate    DATE          NULL,
    IsActive   BIT           NOT NULL,
    Budget     DECIMAL(14,2) NULL
);

CREATE TABLE biz.ProjectAssignments (
    Id                 INT           NOT NULL CONSTRAINT PK_ProjectAssignments PRIMARY KEY,
    EmployeeId         INT           NOT NULL CONSTRAINT FK_PA_Employees REFERENCES biz.Employees(Id),
    ProjectId          INT           NOT NULL CONSTRAINT FK_PA_Projects REFERENCES biz.Projects(Id),
    Role               NVARCHAR(50)  NOT NULL,
    AllocationPercent  INT           NOT NULL,
    StartDate          DATE          NOT NULL,
    EndDate            DATE          NULL
);

/* Indexes: every FK column (supports correlated EXISTS and LEFT JOIN) + frequent filters */
CREATE INDEX IX_Employees_DepartmentId ON biz.Employees(DepartmentId);
CREATE INDEX IX_Employees_PositionId   ON biz.Employees(PositionId);
CREATE INDEX IX_Employees_ManagerId    ON biz.Employees(ManagerId);
CREATE INDEX IX_Employees_Status       ON biz.Employees(Status, DepartmentId);
CREATE INDEX IX_Departments_IsActive   ON biz.Departments(IsActive);
CREATE INDEX IX_PA_EmployeeId          ON biz.ProjectAssignments(EmployeeId) INCLUDE (StartDate, EndDate, ProjectId);
CREATE INDEX IX_PA_ProjectId           ON biz.ProjectAssignments(ProjectId);
GO
GO

/* ===== 03_dq_schema.sql ===== */
/* 03 - System schema: business metadata catalog, rule definitions, versions, runs, violations, AI suggestions */
USE DataControls;
GO
CREATE TABLE dq.Entity (
    Id                 INT IDENTITY  NOT NULL CONSTRAINT PK_Entity PRIMARY KEY,
    [Key]              NVARCHAR(64)  NOT NULL CONSTRAINT UQ_Entity_Key UNIQUE,
    DisplayName        NVARCHAR(100) NOT NULL,
    DisplayNamePlural  NVARCHAR(100) NOT NULL,
    Description        NVARCHAR(400) NULL,
    SchemaName         SYSNAME       NOT NULL,
    TableName          SYSNAME       NOT NULL,
    PrimaryKeyColumn   SYSNAME       NOT NULL,
    DisplayFieldKey    NVARCHAR(64)  NOT NULL,
    IsActive           BIT           NOT NULL CONSTRAINT DF_Entity_IsActive DEFAULT 1
);

CREATE TABLE dq.Field (
    Id                    INT IDENTITY  NOT NULL CONSTRAINT PK_Field PRIMARY KEY,
    EntityId              INT           NOT NULL CONSTRAINT FK_Field_Entity REFERENCES dq.Entity(Id),
    [Key]                 NVARCHAR(64)  NOT NULL,
    DisplayName           NVARCHAR(100) NOT NULL,
    Description           NVARCHAR(400) NULL,
    ColumnName            SYSNAME       NULL,        -- NULL for computed fields
    DataType              NVARCHAR(20)  NOT NULL,    -- String | Integer | Decimal | Date | DateTime | Boolean | Enum
    IsNullable            BIT           NOT NULL,
    IsRequiredByBusiness  BIT           NOT NULL CONSTRAINT DF_Field_Req DEFAULT 0,
    IsSensitive           BIT           NOT NULL CONSTRAINT DF_Field_Sens DEFAULT 0,
    Unit                  NVARCHAR(20)  NULL,
    MaxLength             INT           NULL,
    ComputedFunction      NVARCHAR(40)  NULL,        -- closed catalog, e.g. ageYears
    ComputedArgFieldKey   NVARCHAR(64)  NULL,
    SortOrder             INT           NOT NULL CONSTRAINT DF_Field_Sort DEFAULT 0,
    IsActive              BIT           NOT NULL CONSTRAINT DF_Field_IsActive DEFAULT 1,
    CONSTRAINT UQ_Field_Key UNIQUE (EntityId, [Key])
);

CREATE TABLE dq.EnumValue (
    Id           INT IDENTITY  NOT NULL CONSTRAINT PK_EnumValue PRIMARY KEY,
    FieldId      INT           NOT NULL CONSTRAINT FK_EnumValue_Field REFERENCES dq.Field(Id),
    Value        NVARCHAR(50)  NOT NULL,
    DisplayName  NVARCHAR(100) NOT NULL,
    SortOrder    INT           NOT NULL CONSTRAINT DF_EnumValue_Sort DEFAULT 0
);

CREATE TABLE dq.Relationship (
    Id            INT IDENTITY  NOT NULL CONSTRAINT PK_Relationship PRIMARY KEY,
    FromEntityId  INT           NOT NULL CONSTRAINT FK_Rel_From REFERENCES dq.Entity(Id),
    [Key]         NVARCHAR(64)  NOT NULL,
    ToEntityId    INT           NOT NULL CONSTRAINT FK_Rel_To REFERENCES dq.Entity(Id),
    Cardinality   NVARCHAR(20)  NOT NULL,            -- ManyToOne | OneToMany
    FromColumn    SYSNAME       NOT NULL,            -- column on the "from" table
    ToColumn      SYSNAME       NOT NULL,            -- column on the "to" table
    DisplayName   NVARCHAR(150) NOT NULL,
    IsActive      BIT           NOT NULL CONSTRAINT DF_Rel_IsActive DEFAULT 1,
    CONSTRAINT UQ_Rel_Key UNIQUE (FromEntityId, [Key])
);

CREATE TABLE dq.[Rule] (
    Id              UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_Rule PRIMARY KEY CONSTRAINT DF_Rule_Id DEFAULT NEWSEQUENTIALID(),
    Name            NVARCHAR(200)    NOT NULL,
    Description     NVARCHAR(1000)   NULL,
    RootEntityKey   NVARCHAR(64)     NOT NULL,
    DefinitionJson  NVARCHAR(MAX)    NOT NULL,
    SchemaVersion   INT              NOT NULL,
    Status          NVARCHAR(20)     NOT NULL,       -- Draft | Active | Archived
    Severity        NVARCHAR(20)     NOT NULL,       -- Low | Medium | High
    Origin          NVARCHAR(20)     NOT NULL,       -- Manual | AI
    CurrentVersion  INT              NOT NULL,
    CreatedBy       NVARCHAR(100)    NOT NULL,
    CreatedAt       DATETIME2(0)     NOT NULL,
    UpdatedBy       NVARCHAR(100)    NOT NULL,
    UpdatedAt       DATETIME2(0)     NOT NULL
);
CREATE INDEX IX_Rule_Status ON dq.[Rule](Status, UpdatedAt DESC);

CREATE TABLE dq.RuleVersion (
    RuleId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT FK_RuleVersion_Rule REFERENCES dq.[Rule](Id),
    VersionNo       INT              NOT NULL,
    Name            NVARCHAR(200)    NOT NULL,
    DefinitionJson  NVARCHAR(MAX)    NOT NULL,
    CreatedBy       NVARCHAR(100)    NOT NULL,
    CreatedAt       DATETIME2(0)     NOT NULL,
    CONSTRAINT PK_RuleVersion PRIMARY KEY (RuleId, VersionNo)
);

CREATE TABLE dq.RuleRun (
    Id              UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_RuleRun PRIMARY KEY,
    RuleId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT FK_RuleRun_Rule REFERENCES dq.[Rule](Id),
    RuleVersionNo   INT              NOT NULL,
    Status          NVARCHAR(20)     NOT NULL,       -- Queued | Running | Succeeded | Failed | TimedOut
    QueuedAt        DATETIME2(3)     NOT NULL,
    StartedAt       DATETIME2(3)     NULL,
    FinishedAt      DATETIME2(3)     NULL,
    DurationMs      INT              NULL,
    ViolationCount  BIGINT           NULL,
    StoredCount     INT              NULL,
    IsTruncated     BIT              NOT NULL CONSTRAINT DF_RuleRun_Trunc DEFAULT 0,
    SqlHash         NVARCHAR(64)     NULL,
    ErrorCode       NVARCHAR(50)     NULL,
    ErrorMessage    NVARCHAR(1000)   NULL,
    TriggeredBy     NVARCHAR(100)    NOT NULL
);
CREATE INDEX IX_RuleRun_Rule ON dq.RuleRun(RuleId, QueuedAt DESC);

CREATE TABLE dq.RuleRunViolation (
    RunId               UNIQUEIDENTIFIER NOT NULL CONSTRAINT FK_Violation_Run REFERENCES dq.RuleRun(Id),
    Seq                 INT              NOT NULL,
    RecordKey           NVARCHAR(100)    NOT NULL,
    DisplayLabel        NVARCHAR(400)    NOT NULL,
    ReasonsJson         NVARCHAR(MAX)    NOT NULL,
    FailedConditionIds  NVARCHAR(1000)   NOT NULL,   -- ",c1,c3," for LIKE filtering
    ValuesJson          NVARCHAR(MAX)    NOT NULL,
    SearchText          NVARCHAR(2000)   NOT NULL,
    CONSTRAINT PK_RuleRunViolation PRIMARY KEY (RunId, Seq)
);

CREATE TABLE dq.AiSuggestion (
    Id                UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_AiSuggestion PRIMARY KEY,
    BatchId           UNIQUEIDENTIFIER NOT NULL,
    Provider          NVARCHAR(50)     NOT NULL,
    Title             NVARCHAR(200)    NOT NULL,
    ExplanationHe     NVARCHAR(2000)   NOT NULL,
    Evidence          NVARCHAR(1000)   NULL,
    Severity          NVARCHAR(20)     NOT NULL,
    DefinitionJson    NVARCHAR(MAX)    NOT NULL,
    Status            NVARCHAR(20)     NOT NULL,     -- Proposed | Accepted | Rejected | Invalid
    ValidationErrors  NVARCHAR(MAX)    NULL,
    CreatedAt         DATETIME2(0)     NOT NULL,
    ReviewedBy        NVARCHAR(100)    NULL,
    ReviewedAt        DATETIME2(0)     NULL,
    AcceptedRuleId    UNIQUEIDENTIFIER NULL
);
CREATE INDEX IX_AiSuggestion_Batch ON dq.AiSuggestion(BatchId);
GO
GO

/* ===== 04_security.sql ===== */
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
GO

/* ===== 05_seed_business.sql ===== */
/* 05 - Deterministic business seed data (no NEWID/GETDATE) with planted errors.

   Planted errors (expected results of the sample controls in 07):
   R1 minor with high salary        : employees 21, 42      (63 = age 17 but salary exactly 15,000; 84 = age 16, low salary)
   R2 termination before hire       : employees 30, 45
   R3 active employee, inactive dept: employees 7, 19, 33   (90 is in an inactive dept but terminated; 111 has no dept)
   R4 missing contact details       : employees 12, 56 (NULL email), 77 (empty-string email), 99 (NULL phone)
   R5 invalid project assignment    : employees 15 (end < start), 25 (starts before hire), 150 (3 bad assignments -> listed once)
   R6 active employee w/o projects  : employees 170, 171
   R7 salary above position maximum : employees 50, 51
   Ages are computed on the run date; employees 21/42/84 stay under 18 until March 2028. */
USE DataControls;
GO
SET NOCOUNT ON;

INSERT INTO biz.Departments (Id, Name, IsActive, CostCenter) VALUES
 (1, N'כספים', 1, N'CC-100'), (2, N'משאבי אנוש', 1, N'CC-110'), (3, N'פיתוח', 1, N'CC-200'),
 (4, N'תשתיות', 1, N'CC-210'), (5, N'שיווק', 1, N'CC-300'), (6, N'מכירות', 1, N'CC-310'),
 (7, N'שירות לקוחות', 1, N'CC-320'), (8, N'רכש', 1, N'CC-400'), (9, N'לוגיסטיקה', 1, N'CC-410'),
 (10, N'משפטית', 1, N'CC-500'), (11, N'מחקר (סגורה)', 0, N'CC-900'), (12, N'פרויקטים מיוחדים (סגורה)', 0, NULL);

INSERT INTO biz.Positions (Id, Title, MinSalary, MaxSalary) VALUES
 (1, N'מתאם', 7000, 30000), (2, N'מנתח', 9000, 30000), (3, N'מפתח', 12000, 30000),
 (4, N'ראש צוות', 15000, 30000), (5, N'מנהל מחלקה', 18000, 30000), (6, N'יועץ', 10000, 30000);

;WITH n AS (
    SELECT TOP (200) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects
)
INSERT INTO biz.Employees (Id, EmployeeNumber, FirstName, LastName, BirthDate, HireDate, TerminationDate,
                           Salary, Status, Email, Phone, DepartmentId, PositionId, ManagerId)
SELECT n,
       N'E' + RIGHT(N'0000' + CAST(n AS NVARCHAR(10)), 4),
       CHOOSE(n % 10 + 1, N'אברהם', N'יצחק', N'יעקב', N'משה', N'אהרן', N'יוסף', N'דוד', N'שלמה', N'שמואל', N'בנימין'),
       CHOOSE(n % 12 + 1, N'כהן', N'לוי', N'מזרחי', N'פרץ', N'ביטון', N'דהן', N'אברהמי', N'פרידמן', N'שפירא', N'רוזנברג', N'קליין', N'גולדברג'),
       DATEADD(DAY, -((n * 137) % 9000), CAST('2001-06-01' AS DATE)),
       DATEADD(DAY, (n * 53) % 3000, CAST('2016-01-01' AS DATE)),
       NULL,
       8000 + (n * 373) % 14000,
       CASE WHEN n % 15 = 0 THEN N'T' ELSE N'A' END,
       N'emp' + CAST(n AS NVARCHAR(10)) + N'@example.co.il',
       N'050-' + RIGHT(N'0000000' + CAST(n * 4513 AS NVARCHAR(10)), 7),
       (n % 10) + 1,
       (n % 6) + 1,
       NULL
FROM n;

UPDATE biz.Employees SET ManagerId = ((Id - 1) % 10) + 1 WHERE Id > 10;
UPDATE biz.Employees SET TerminationDate = DATEADD(DAY, 400, HireDate) WHERE Status = N'T';
UPDATE biz.Departments SET ManagerEmployeeId = Id WHERE Id <= 10;

/* ---- planted errors ---- */
-- R1: minors with salary > 15,000 (21, 42); boundary/negative cases (63, 84)
UPDATE biz.Employees SET BirthDate = '2010-03-01', Salary = 17500 WHERE Id IN (21, 42);
UPDATE biz.Employees SET BirthDate = '2009-01-01', Salary = 15000 WHERE Id = 63;
UPDATE biz.Employees SET BirthDate = '2010-03-01', Salary = 9000  WHERE Id = 84;
-- R2: termination before hire
UPDATE biz.Employees SET TerminationDate = DATEADD(DAY, -30, HireDate) WHERE Id IN (30, 45);
-- R3: active employees in an inactive department; negative cases 90 (terminated) and 111 (no department)
UPDATE biz.Employees SET DepartmentId = 11 WHERE Id IN (7, 19, 33);
UPDATE biz.Employees SET DepartmentId = 12 WHERE Id = 90;
UPDATE biz.Employees SET DepartmentId = NULL WHERE Id = 111;
-- R4: missing contact details (NULL vs empty string)
UPDATE biz.Employees SET Email = NULL WHERE Id IN (12, 56);
UPDATE biz.Employees SET Email = N''  WHERE Id = 77;
UPDATE biz.Employees SET Phone = NULL WHERE Id = 99;
-- R7: salary above position maximum (cross-entity field-to-field)
UPDATE biz.Employees SET Salary = 32000 WHERE Id IN (50, 51);

;WITH n AS (
    SELECT TOP (25) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects
)
INSERT INTO biz.Projects (Id, Name, StartDate, EndDate, IsActive, Budget)
SELECT n, N'פרויקט ' + CAST(n AS NVARCHAR(10)),
       DATEADD(MONTH, n, CAST('2015-01-01' AS DATE)),
       CASE WHEN n % 5 = 0 THEN DATEADD(YEAR, 2, DATEADD(MONTH, n, CAST('2015-01-01' AS DATE))) END,
       CASE WHEN n % 5 = 0 THEN 0 ELSE 1 END,
       100000 + n * 25000
FROM n;

INSERT INTO biz.ProjectAssignments (Id, EmployeeId, ProjectId, Role, AllocationPercent, StartDate, EndDate)
SELECT e.Id * 2 - 1, e.Id, ((e.Id * 7) % 25) + 1, N'חבר צוות', 50,
       DATEADD(DAY, 30 + e.Id % 90, e.HireDate), NULL
FROM biz.Employees e
UNION ALL
SELECT e.Id * 2, e.Id, ((e.Id * 11 + 3) % 25) + 1, N'יועץ', 50,
       DATEADD(DAY, 30 + e.Id % 90, e.HireDate), DATEADD(DAY, 210 + e.Id % 90, e.HireDate)
FROM biz.Employees e;

-- R5: assignment ends before it starts (employee 15), starts before hire (employee 25),
--     employee 150 gets 3 extra invalid assignments (must still appear ONCE in the results)
UPDATE biz.ProjectAssignments SET EndDate = DATEADD(DAY, -10, StartDate) WHERE Id = 30;
UPDATE pa SET StartDate = DATEADD(DAY, -20, e.HireDate)
FROM biz.ProjectAssignments pa JOIN biz.Employees e ON e.Id = pa.EmployeeId WHERE pa.Id = 49;
INSERT INTO biz.ProjectAssignments (Id, EmployeeId, ProjectId, Role, AllocationPercent, StartDate, EndDate)
SELECT 1000 + k, 150, k, N'חבר צוות', 20, DATEADD(DAY, -5, (SELECT HireDate FROM biz.Employees WHERE Id = 150)), NULL
FROM (VALUES (1), (2), (3)) v(k);
-- R6: active employees with no project assignments
DELETE FROM biz.ProjectAssignments WHERE EmployeeId IN (170, 171);
GO
GO

/* ===== 06_seed_metadata.sql ===== */
/* 06 - Business metadata catalog. This is the ONLY place that maps business terms to physical
   tables/columns. Adding a new entity = adding rows here (no engine code change). */
USE DataControls;
GO
SET NOCOUNT ON;

INSERT INTO dq.Entity ([Key], DisplayName, DisplayNamePlural, Description, SchemaName, TableName, PrimaryKeyColumn, DisplayFieldKey) VALUES
 (N'employee',          N'עובד',          N'עובדים',          N'כל העובדים בארגון, פעילים ושעזבו', N'biz', N'Employees',          N'Id', N'fullName'),
 (N'department',        N'מחלקה',         N'מחלקות',          N'מחלקות הארגון',                     N'biz', N'Departments',        N'Id', N'name'),
 (N'position',          N'תפקיד',         N'תפקידים',         N'הגדרות תפקיד וטווחי שכר',           N'biz', N'Positions',          N'Id', N'title'),
 (N'project',           N'פרויקט',        N'פרויקטים',        N'פרויקטים בארגון',                   N'biz', N'Projects',           N'Id', N'name'),
 (N'projectAssignment', N'שיוך לפרויקט',  N'שיוכים לפרויקטים', N'שיוך של עובד לפרויקט לתקופה',      N'biz', N'ProjectAssignments', N'Id', N'role');

DECLARE @emp INT = (SELECT Id FROM dq.Entity WHERE [Key] = N'employee');
DECLARE @dep INT = (SELECT Id FROM dq.Entity WHERE [Key] = N'department');
DECLARE @pos INT = (SELECT Id FROM dq.Entity WHERE [Key] = N'position');
DECLARE @prj INT = (SELECT Id FROM dq.Entity WHERE [Key] = N'project');
DECLARE @pa  INT = (SELECT Id FROM dq.Entity WHERE [Key] = N'projectAssignment');

INSERT INTO dq.Field (EntityId, [Key], DisplayName, Description, ColumnName, DataType, IsNullable, IsRequiredByBusiness, IsSensitive, Unit, MaxLength, ComputedFunction, ComputedArgFieldKey, SortOrder) VALUES
 (@emp, N'employeeNumber',  N'מספר עובד',         NULL,                               N'EmployeeNumber',  N'String',  0, 1, 0, NULL, 20,  NULL, NULL, 1),
 (@emp, N'firstName',       N'שם פרטי',           NULL,                               N'FirstName',       N'String',  0, 1, 0, NULL, 50,  NULL, NULL, 2),
 (@emp, N'lastName',        N'שם משפחה',          NULL,                               N'LastName',        N'String',  0, 1, 0, NULL, 50,  NULL, NULL, 3),
 (@emp, N'fullName',        N'שם מלא',            N'שם פרטי ושם משפחה',               NULL,               N'String',  0, 0, 0, NULL, 101, N'fullName', N'firstName,lastName', 4),
 (@emp, N'birthDate',       N'תאריך לידה',        NULL,                               N'BirthDate',       N'Date',    1, 1, 1, NULL, NULL, NULL, NULL, 5),
 (@emp, N'age',             N'גיל',               N'גיל בשנים שלמות, מחושב לפי תאריך ההרצה', NULL,            N'Integer', 1, 0, 0, N'שנים', NULL, N'ageYears', N'birthDate', 6),
 (@emp, N'hireDate',        N'תאריך תחילת העסקה', NULL,                               N'HireDate',        N'Date',    0, 1, 0, NULL, NULL, NULL, NULL, 7),
 (@emp, N'terminationDate', N'תאריך סיום העסקה',  N'ריק לעובד פעיל',                  N'TerminationDate', N'Date',    1, 0, 0, NULL, NULL, NULL, NULL, 8),
 (@emp, N'salary',          N'שכר חודשי',         NULL,                               N'Salary',          N'Decimal', 0, 1, 1, N'₪',   NULL, NULL, NULL, 9),
 (@emp, N'status',          N'סטטוס',             NULL,                               N'Status',          N'Enum',    0, 1, 0, NULL, 1,   NULL, NULL, 10),
 (@emp, N'email',           N'דוא"ל',             NULL,                               N'Email',           N'String',  1, 1, 0, NULL, 200, NULL, NULL, 11),
 (@emp, N'phone',           N'טלפון',             NULL,                               N'Phone',           N'String',  1, 1, 1, NULL, 30,  NULL, NULL, 12),
 (@dep, N'name',            N'שם המחלקה',         NULL,                               N'Name',            N'String',  0, 1, 0, NULL, 100, NULL, NULL, 1),
 (@dep, N'isActive',        N'פעילה',             NULL,                               N'IsActive',        N'Boolean', 0, 1, 0, NULL, NULL, NULL, NULL, 2),
 (@dep, N'costCenter',      N'מרכז עלות',         NULL,                               N'CostCenter',      N'String',  1, 1, 0, NULL, 20,  NULL, NULL, 3),
 (@pos, N'title',           N'שם התפקיד',         NULL,                               N'Title',           N'String',  0, 1, 0, NULL, 100, NULL, NULL, 1),
 (@pos, N'minSalary',       N'שכר מינימלי לתפקיד', NULL,                              N'MinSalary',       N'Decimal', 0, 1, 0, N'₪',   NULL, NULL, NULL, 2),
 (@pos, N'maxSalary',       N'שכר מקסימלי לתפקיד', NULL,                              N'MaxSalary',       N'Decimal', 0, 1, 0, N'₪',   NULL, NULL, NULL, 3),
 (@prj, N'name',            N'שם הפרויקט',        NULL,                               N'Name',            N'String',  0, 1, 0, NULL, 100, NULL, NULL, 1),
 (@prj, N'startDate',       N'תאריך התחלה',       NULL,                               N'StartDate',       N'Date',    0, 1, 0, NULL, NULL, NULL, NULL, 2),
 (@prj, N'endDate',         N'תאריך סיום',        NULL,                               N'EndDate',         N'Date',    1, 0, 0, NULL, NULL, NULL, NULL, 3),
 (@prj, N'isActive',        N'פעיל',              NULL,                               N'IsActive',        N'Boolean', 0, 1, 0, NULL, NULL, NULL, NULL, 4),
 (@prj, N'budget',          N'תקציב',             NULL,                               N'Budget',          N'Decimal', 1, 0, 0, N'₪',   NULL, NULL, NULL, 5),
 (@pa,  N'role',            N'תפקיד בפרויקט',     NULL,                               N'Role',            N'String',  0, 1, 0, NULL, 50,  NULL, NULL, 1),
 (@pa,  N'allocationPercent', N'אחוז משרה בפרויקט', NULL,                             N'AllocationPercent', N'Integer', 0, 1, 0, N'%', NULL, NULL, NULL, 2),
 (@pa,  N'startDate',       N'תאריך תחילת השיוך', NULL,                               N'StartDate',       N'Date',    0, 1, 0, NULL, NULL, NULL, NULL, 3),
 (@pa,  N'endDate',         N'תאריך סיום השיוך',  NULL,                               N'EndDate',         N'Date',    1, 0, 0, NULL, NULL, NULL, NULL, 4);

INSERT INTO dq.EnumValue (FieldId, Value, DisplayName, SortOrder)
SELECT f.Id, v.Value, v.DisplayName, v.SortOrder
FROM dq.Field f
CROSS JOIN (VALUES (N'A', N'פעיל', 1), (N'T', N'סיים עבודה', 2)) v(Value, DisplayName, SortOrder)
WHERE f.EntityId = @emp AND f.[Key] = N'status';

INSERT INTO dq.Relationship (FromEntityId, [Key], ToEntityId, Cardinality, FromColumn, ToColumn, DisplayName) VALUES
 (@emp, N'department',         @dep, N'ManyToOne', N'DepartmentId',      N'Id',           N'המחלקה של העובד'),
 (@emp, N'position',           @pos, N'ManyToOne', N'PositionId',        N'Id',           N'התפקיד של העובד'),
 (@emp, N'manager',            @emp, N'ManyToOne', N'ManagerId',         N'Id',           N'המנהל הישיר'),
 (@emp, N'projectAssignments', @pa,  N'OneToMany', N'Id',                N'EmployeeId',   N'שיוכי הפרויקטים של העובד'),
 (@dep, N'employees',          @emp, N'OneToMany', N'Id',                N'DepartmentId', N'העובדים במחלקה'),
 (@dep, N'manager',            @emp, N'ManyToOne', N'ManagerEmployeeId', N'Id',           N'מנהל המחלקה'),
 (@prj, N'assignments',        @pa,  N'OneToMany', N'Id',                N'ProjectId',    N'שיוכי העובדים לפרויקט'),
 (@pa,  N'employee',           @emp, N'ManyToOne', N'EmployeeId',        N'Id',           N'העובד המשויך'),
 (@pa,  N'project',            @prj, N'ManyToOne', N'ProjectId',         N'Id',           N'הפרויקט');
GO
GO

/* ===== 07_seed_sample_rules.sql ===== */
/* 07 - Sample controls (stored as JSON AST, exactly like controls created in the UI) */
USE DataControls;
GO
SET NOCOUNT ON;

DECLARE @r TABLE (Id UNIQUEIDENTIFIER, Name NVARCHAR(200), Description NVARCHAR(1000), Severity NVARCHAR(20), Def NVARCHAR(MAX));

INSERT INTO @r VALUES
('11111111-0000-0000-0000-000000000001', N'קטין עם שכר גבוה', N'עובדים שגילם נמוך מ־18 ושכרם גבוה מ־15,000 ש"ח', N'High',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"and","negate":false,"children":[
   {"type":"comparison","id":"c1","left":{"kind":"field","path":["age"]},"operator":"lt","right":{"kind":"value","value":18}},
   {"type":"comparison","id":"c2","left":{"kind":"field","path":["salary"]},"operator":"gt","right":{"kind":"value","value":15000}}]},
   "output":{"displayFields":["fullName","age","salary"]}}'),
('11111111-0000-0000-0000-000000000002', N'סיום העסקה לפני תחילתה', N'תאריך סיום העסקה מוקדם מתאריך תחילת העסקה', N'High',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"and","negate":false,"children":[
   {"type":"comparison","id":"c1","left":{"kind":"field","path":["terminationDate"]},"operator":"lt","right":{"kind":"field","path":["hireDate"]}}]},
   "output":{"displayFields":["fullName","hireDate","terminationDate"]}}'),
('11111111-0000-0000-0000-000000000003', N'עובד פעיל במחלקה לא פעילה', N'עובדים פעילים המשויכים למחלקה שאינה פעילה', N'Medium',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"and","negate":false,"children":[
   {"type":"comparison","id":"c1","left":{"kind":"field","path":["status"]},"operator":"eq","right":{"kind":"value","value":"A"}},
   {"type":"comparison","id":"c2","left":{"kind":"field","path":["department","isActive"]},"operator":"eq","right":{"kind":"value","value":false}}]},
   "output":{"displayFields":["fullName","department.name"]}}'),
('11111111-0000-0000-0000-000000000004', N'חסרים פרטי קשר', N'דוא"ל או טלפון חסרים, למרות שהם חובה לפי הכללים העסקיים', N'Low',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"or","negate":false,"children":[
   {"type":"comparison","id":"c1","left":{"kind":"field","path":["email"]},"operator":"isEmpty"},
   {"type":"comparison","id":"c2","left":{"kind":"field","path":["phone"]},"operator":"isEmpty"}]},
   "output":{"displayFields":["fullName","email"]}}'),
('11111111-0000-0000-0000-000000000005', N'שיוך פרויקט לא תקין', N'לפחות שיוך אחד שמסתיים לפני שהתחיל, או שמתחיל לפני קליטת העובד', N'Medium',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"and","negate":false,"children":[
   {"type":"collection","id":"q1","relation":"projectAssignments","quantifier":"any","condition":
     {"type":"group","id":"g2","logic":"or","negate":false,"children":[
       {"type":"comparison","id":"c1","left":{"kind":"field","path":["endDate"]},"operator":"lt","right":{"kind":"field","path":["startDate"]}},
       {"type":"comparison","id":"c2","left":{"kind":"field","path":["startDate"]},"operator":"lt","right":{"kind":"field","scope":"root","path":["hireDate"]}}]}}]},
   "output":{"displayFields":["fullName","hireDate"]}}'),
('11111111-0000-0000-0000-000000000006', N'עובד פעיל ללא שיוך לפרויקט', N'עובדים פעילים שאין להם אף שיוך לפרויקט', N'Low',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"and","negate":false,"children":[
   {"type":"comparison","id":"c1","left":{"kind":"field","path":["status"]},"operator":"eq","right":{"kind":"value","value":"A"}},
   {"type":"collection","id":"q1","relation":"projectAssignments","quantifier":"none"}]},
   "output":{"displayFields":["fullName","department.name"]}}'),
('11111111-0000-0000-0000-000000000007', N'שכר מעל טווח התפקיד', N'שכר העובד גבוה מהשכר המקסימלי שהוגדר לתפקיד שלו', N'Medium',
 N'{"schemaVersion":1,"rootEntity":"employee","condition":{"type":"group","id":"g1","logic":"and","negate":false,"children":[
   {"type":"comparison","id":"c1","left":{"kind":"field","path":["salary"]},"operator":"gt","right":{"kind":"field","path":["position","maxSalary"]}}]},
   "output":{"displayFields":["fullName","position.title","salary"]}}');

DECLARE @now DATETIME2(0) = SYSUTCDATETIME();

INSERT INTO dq.[Rule] (Id, Name, Description, RootEntityKey, DefinitionJson, SchemaVersion, Status, Severity, Origin, CurrentVersion, CreatedBy, CreatedAt, UpdatedBy, UpdatedAt)
SELECT Id, Name, Description, N'employee', Def, 1, N'Active', Severity, N'Manual', 1, N'seed', @now, N'seed', @now FROM @r;

INSERT INTO dq.RuleVersion (RuleId, VersionNo, Name, DefinitionJson, CreatedBy, CreatedAt)
SELECT Id, 1, Name, Def, N'seed', @now FROM @r;
GO
GO
