/* =============================================================================
   ERP Error Management Framework
   Script 001 - Schema, versioning table, configuration (lookup) tables
   Target   : SQL Server 2016 SP1+ (uses sp_set_session_context, STRING_SPLIT,
              DATETIME2, SEQUENCE).  Verified syntax against SQL Server 2016/2019/2022.
   Idempotent: yes - safe to re-run.

   DESIGN NOTE
   -----------
   Every object created by this framework lives in the [erp_err] schema and is
   prefixed by nothing else.  No existing ERP table, view, procedure, function,
   trigger, user or role is read, altered or dropped by any script in this folder.
   The only privilege the framework needs on the host database is the ability to
   create and use its own schema; the application login needs nothing more than
   EXECUTE on [erp_err] (see 006_security.sql).
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------------------------------------------------------------- schema -- */
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'erp_err')
    EXEC (N'CREATE SCHEMA [erp_err] AUTHORIZATION [dbo];');
GO

/* --------------------------------------------------- migration history --- */
/* The framework versions its own database objects.  Every script in this
   folder records itself here, so an upgrade can tell exactly which scripts a
   given environment has already had applied.  This is the "how is the
   framework deployed and versioned in the database" answer: plain, ordered,
   idempotent SQL scripts + this ledger, applied by DbUp (or by hand).        */
IF OBJECT_ID(N'erp_err.SchemaVersion', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.SchemaVersion
    (
        ScriptName      NVARCHAR(255)   NOT NULL,
        AppliedUtc      DATETIME2(3)    NOT NULL CONSTRAINT DF_SchemaVersion_AppliedUtc DEFAULT (SYSUTCDATETIME()),
        AppliedBy       NVARCHAR(128)   NOT NULL CONSTRAINT DF_SchemaVersion_AppliedBy  DEFAULT (SUSER_SNAME()),
        FrameworkVersion NVARCHAR(32)   NULL,
        CONSTRAINT PK_SchemaVersion PRIMARY KEY CLUSTERED (ScriptName)
    );
END
GO

/* =============================================================================
   CONFIGURATION TABLES
   -----------------------------------------------------------------------------
   Everything the brief asked to be "configurable rather than hard-coded" is a
   row in one of these tables, not a constant in code: severities, categories,
   ticket statuses, the allowed status transitions, queues, SLA targets,
   auto-ticket rules, retention policies and redaction rules.
   ============================================================================= */

/* ------------------------------------------------------------- severity -- */
IF OBJECT_ID(N'erp_err.Severity', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.Severity
    (
        SeverityId      TINYINT         NOT NULL,
        Code            NVARCHAR(20)    NOT NULL,
        DisplayName     NVARCHAR(50)    NOT NULL,
        RankOrder       TINYINT         NOT NULL,   -- 1 = most severe
        IsActive        BIT             NOT NULL CONSTRAINT DF_Severity_IsActive DEFAULT (1),
        CONSTRAINT PK_Severity PRIMARY KEY CLUSTERED (SeverityId),
        CONSTRAINT UQ_Severity_Code UNIQUE (Code)
    );
END
GO

/* ------------------------------------------------------------- category -- */
IF OBJECT_ID(N'erp_err.ErrorCategory', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.ErrorCategory
    (
        CategoryId      SMALLINT        NOT NULL,
        Code            NVARCHAR(40)    NOT NULL,
        DisplayName     NVARCHAR(100)   NOT NULL,
        -- Default severity applied when the classifier resolves to this category
        -- and the caller did not specify one explicitly.
        DefaultSeverityId TINYINT       NOT NULL,
        IsActive        BIT             NOT NULL CONSTRAINT DF_ErrorCategory_IsActive DEFAULT (1),
        CONSTRAINT PK_ErrorCategory PRIMARY KEY CLUSTERED (CategoryId),
        CONSTRAINT UQ_ErrorCategory_Code UNIQUE (Code),
        CONSTRAINT FK_ErrorCategory_Severity FOREIGN KEY (DefaultSeverityId)
            REFERENCES erp_err.Severity (SeverityId)
    );
END
GO

/* ---------------------------------------------------------------- layer -- */
IF OBJECT_ID(N'erp_err.AppLayer', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.AppLayer
    (
        LayerId         TINYINT         NOT NULL,
        Code            NVARCHAR(30)    NOT NULL,
        DisplayName     NVARCHAR(60)    NOT NULL,
        CONSTRAINT PK_AppLayer PRIMARY KEY CLUSTERED (LayerId),
        CONSTRAINT UQ_AppLayer_Code UNIQUE (Code)
    );
END
GO

/* -------------------------------------------------------------- statuses -- */
IF OBJECT_ID(N'erp_err.TicketStatus', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.TicketStatus
    (
        StatusId        TINYINT         NOT NULL,
        Code            NVARCHAR(40)    NOT NULL,
        DisplayName     NVARCHAR(80)    NOT NULL,
        RankOrder       TINYINT         NOT NULL,
        -- IsOpen drives "is this ticket still consuming SLA / still in a queue".
        IsOpen          BIT             NOT NULL CONSTRAINT DF_TicketStatus_IsOpen DEFAULT (1),
        -- IsTerminal marks Closed/Cancelled: no further transitions allowed.
        IsTerminal      BIT             NOT NULL CONSTRAINT DF_TicketStatus_IsTerminal DEFAULT (0),
        -- Time spent in a status flagged IsPaused does NOT count toward active
        -- processing time (that is what "Waiting for Information" is for).
        IsPaused        BIT             NOT NULL CONSTRAINT DF_TicketStatus_IsPaused DEFAULT (0),
        IsActive        BIT             NOT NULL CONSTRAINT DF_TicketStatus_IsActive DEFAULT (1),
        CONSTRAINT PK_TicketStatus PRIMARY KEY CLUSTERED (StatusId),
        CONSTRAINT UQ_TicketStatus_Code UNIQUE (Code)
    );
END
GO

/* The lifecycle itself is data, not code.  Adding a status or re-wiring the
   workflow is an INSERT here - no redeploy of the API or the Angular app.     */
IF OBJECT_ID(N'erp_err.TicketStatusTransition', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.TicketStatusTransition
    (
        FromStatusId    TINYINT         NOT NULL,
        ToStatusId      TINYINT         NOT NULL,
        RequiresComment BIT             NOT NULL CONSTRAINT DF_TST_RequiresComment DEFAULT (0),
        RequiresAssignee BIT            NOT NULL CONSTRAINT DF_TST_RequiresAssignee DEFAULT (0),
        IsActive        BIT             NOT NULL CONSTRAINT DF_TST_IsActive DEFAULT (1),
        CONSTRAINT PK_TicketStatusTransition PRIMARY KEY CLUSTERED (FromStatusId, ToStatusId),
        CONSTRAINT FK_TST_From FOREIGN KEY (FromStatusId) REFERENCES erp_err.TicketStatus (StatusId),
        CONSTRAINT FK_TST_To   FOREIGN KEY (ToStatusId)   REFERENCES erp_err.TicketStatus (StatusId)
    );
END
GO

/* ---------------------------------------------------------------- queues -- */
IF OBJECT_ID(N'erp_err.TicketQueue', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.TicketQueue
    (
        QueueId         SMALLINT        IDENTITY(1,1) NOT NULL,
        Code            NVARCHAR(40)    NOT NULL,
        DisplayName     NVARCHAR(100)   NOT NULL,
        -- Optional routing hint: tickets whose error came from this ERP module
        -- land in this queue.  NULL = the catch-all queue.
        ErpModuleMatch  NVARCHAR(100)   NULL,
        IsDefault       BIT             NOT NULL CONSTRAINT DF_TicketQueue_IsDefault DEFAULT (0),
        IsActive        BIT             NOT NULL CONSTRAINT DF_TicketQueue_IsActive DEFAULT (1),
        CONSTRAINT PK_TicketQueue PRIMARY KEY CLUSTERED (QueueId),
        CONSTRAINT UQ_TicketQueue_Code UNIQUE (Code)
    );
END
GO

/* ------------------------------------------------------------------ SLA -- */
IF OBJECT_ID(N'erp_err.SlaPolicy', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.SlaPolicy
    (
        SlaPolicyId     SMALLINT        IDENTITY(1,1) NOT NULL,
        SeverityId      TINYINT         NOT NULL,
        QueueId         SMALLINT        NULL,          -- NULL = applies to all queues
        FirstResponseMinutes INT        NOT NULL,
        ResolutionMinutes    INT        NOT NULL,
        IsActive        BIT             NOT NULL CONSTRAINT DF_SlaPolicy_IsActive DEFAULT (1),
        CONSTRAINT PK_SlaPolicy PRIMARY KEY CLUSTERED (SlaPolicyId),
        CONSTRAINT FK_SlaPolicy_Severity FOREIGN KEY (SeverityId) REFERENCES erp_err.Severity (SeverityId),
        CONSTRAINT FK_SlaPolicy_Queue    FOREIGN KEY (QueueId)    REFERENCES erp_err.TicketQueue (QueueId)
    );
    CREATE UNIQUE INDEX UX_SlaPolicy_Sev_Queue ON erp_err.SlaPolicy (SeverityId, QueueId)
        WHERE IsActive = 1;
END
GO

/* ------------------------------------------------- generic settings bag -- */
/* Read by the API at startup and cached for [CacheSeconds]; a change here is
   picked up without an application restart.                                   */
IF OBJECT_ID(N'erp_err.Setting', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.Setting
    (
        SettingKey      NVARCHAR(100)   NOT NULL,
        SettingValue    NVARCHAR(400)   NULL,
        DataType        NVARCHAR(20)    NOT NULL CONSTRAINT DF_Setting_DataType DEFAULT (N'string'),
        Description     NVARCHAR(400)   NULL,
        ModifiedUtc     DATETIME2(3)    NOT NULL CONSTRAINT DF_Setting_ModifiedUtc DEFAULT (SYSUTCDATETIME()),
        ModifiedBy      NVARCHAR(128)   NULL,
        CONSTRAINT PK_Setting PRIMARY KEY CLUSTERED (SettingKey)
    );
END
GO

/* --------------------------------------------------- auto-ticket rules --- */
/* The brief asks that NOT every captured error becomes a ticket.  Errors are
   always logged; a ticket is created only when (a) the user presses "Report
   issue" in the modal, or (b) one of these rules fires.  A rule is evaluated
   against the freshly written occurrence and its fingerprint's rolling count. */
IF OBJECT_ID(N'erp_err.AutoTicketRule', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.AutoTicketRule
    (
        RuleId          SMALLINT        IDENTITY(1,1) NOT NULL,
        RuleName        NVARCHAR(100)   NOT NULL,
        -- All non-NULL predicates must match (AND).  NULL = "don't care".
        MinSeverityId   TINYINT         NULL,          -- severity at least this severe (RankOrder <=)
        CategoryId      SMALLINT        NULL,
        LayerId         TINYINT         NULL,
        ErpModuleMatch  NVARCHAR(100)   NULL,
        EnvironmentMatch NVARCHAR(40)   NULL,
        -- Threshold: fire once the fingerprint has been seen this many times
        -- within the window.  1 + 0 = "fire on the first occurrence".
        MinOccurrences  INT             NOT NULL CONSTRAINT DF_AutoTicketRule_MinOcc DEFAULT (1),
        WindowMinutes   INT             NOT NULL CONSTRAINT DF_AutoTicketRule_Window DEFAULT (60),
        TargetQueueId   SMALLINT        NULL,
        IsActive        BIT             NOT NULL CONSTRAINT DF_AutoTicketRule_IsActive DEFAULT (1),
        CONSTRAINT PK_AutoTicketRule PRIMARY KEY CLUSTERED (RuleId),
        CONSTRAINT FK_AutoTicketRule_Severity FOREIGN KEY (MinSeverityId) REFERENCES erp_err.Severity (SeverityId),
        CONSTRAINT FK_AutoTicketRule_Category FOREIGN KEY (CategoryId)    REFERENCES erp_err.ErrorCategory (CategoryId),
        CONSTRAINT FK_AutoTicketRule_Layer    FOREIGN KEY (LayerId)       REFERENCES erp_err.AppLayer (LayerId),
        CONSTRAINT FK_AutoTicketRule_Queue    FOREIGN KEY (TargetQueueId) REFERENCES erp_err.TicketQueue (QueueId)
    );
END
GO

/* ------------------------------------------------------ redaction rules -- */
/* Allow-list, not deny-list.  The capture pipeline keeps ONLY the keys named
   here and replaces every other value with '***'.  A deny-list ("redact
   anything called password") silently leaks the next field somebody invents;
   an allow-list fails closed.                                                 */
IF OBJECT_ID(N'erp_err.RedactionAllowList', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.RedactionAllowList
    (
        RedactionId     SMALLINT        IDENTITY(1,1) NOT NULL,
        -- Scope: 'header' | 'query' | 'body' | 'cookie' | 'route'
        Scope           NVARCHAR(20)    NOT NULL,
        -- Case-insensitive key that is safe to persist in full.
        KeyName         NVARCHAR(100)   NOT NULL,
        IsActive        BIT             NOT NULL CONSTRAINT DF_Redaction_IsActive DEFAULT (1),
        CONSTRAINT PK_RedactionAllowList PRIMARY KEY CLUSTERED (RedactionId),
        CONSTRAINT UQ_Redaction_Scope_Key UNIQUE (Scope, KeyName)
    );
END
GO

/* ------------------------------------------------------ retention policy -- */
IF OBJECT_ID(N'erp_err.RetentionPolicy', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.RetentionPolicy
    (
        PolicyId        SMALLINT        IDENTITY(1,1) NOT NULL,
        -- Which data set this policy governs.
        -- 'occurrence' | 'occurrence_detail' | 'ticket' | 'audit'
        DataSet         NVARCHAR(40)    NOT NULL,
        -- Rows older than this move to the *_Archive table.  0 = never archive.
        ArchiveAfterDays INT            NOT NULL,
        -- Rows older than this are deleted from the archive.  0 = keep forever.
        PurgeAfterDays  INT             NOT NULL,
        -- Batch size per delete/insert loop, so the job never takes a long lock.
        BatchSize       INT             NOT NULL CONSTRAINT DF_RetentionPolicy_Batch DEFAULT (5000),
        IsActive        BIT             NOT NULL CONSTRAINT DF_RetentionPolicy_IsActive DEFAULT (1),
        CONSTRAINT PK_RetentionPolicy PRIMARY KEY CLUSTERED (PolicyId),
        CONSTRAINT UQ_RetentionPolicy_DataSet UNIQUE (DataSet)
    );
END
GO

MERGE erp_err.SchemaVersion AS t
USING (SELECT N'001_schema_and_config.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion) VALUES (s.ScriptName, N'1.0.0');
GO
