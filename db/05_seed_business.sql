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
