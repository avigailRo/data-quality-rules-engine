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
