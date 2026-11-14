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
