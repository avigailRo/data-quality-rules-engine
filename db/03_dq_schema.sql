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
