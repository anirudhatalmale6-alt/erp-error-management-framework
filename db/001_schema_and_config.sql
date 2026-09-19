/* =============================================================================
   ERP Error Management Framework
   Script 001 - Schema, versioning table, configuration (lookup) tables
   Target   : SQL Server 2016 SP1+ (uses sp_set_session_context, STRING_SPLIT,
              DATETIME2, SEQUENCE).  Verified syntax against SQL Server 2016/2019/2022.
   Idempotent: yes - safe to re-run.

   DESIGN NOTE
   -----------
   Every object created by this framework lives in the [ERM] schema and is
   prefixed by nothing else.  No existing ERP table, view, procedure, function,
   trigger, user or role is read, altered or dropped by any script in this folder.
   The only privilege the framework needs on the host database is the ability to
   create and use its own schema; the application login needs nothing more than
   EXECUTE on [ERM] (see 006_security.sql).
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------------------------------------------------------------- schema -- */
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'ERM')
    EXEC (N'CREATE SCHEMA [ERM] AUTHORIZATION [dbo];');
GO

/* =============================================================================
   THE NON-USER VALUE  (-1)
   -----------------------------------------------------------------------------
   The LinkedScam standard requires CreatedBy INT NOT NULL on every table, and
   ATC's rule is that CreatedBy / UpdatedBy carry NO DEFAULT CONSTRAINT: the
   value is supplied by the caller, from the ERP UserProfileID the API or the
   stored procedure already receives.

   No column in this framework has a default on CreatedBy or UpdatedBy. Every
   INSERT names the column and passes a value. That is enforced, not just
   intended - the verification suite walks the parse tree of every script and
   fails if an INSERT into an ERM table omits CreatedBy, or if any table grows
   a default on it again.

   Some rows genuinely have no ERP user behind them:

     * an error captured from a PUBLIC page, where the browser has no token;
     * reference data seeded by these deployment scripts;
     * a ticket raised by an automatic rule rather than by a person;
     * a retention run started by SQL Agent at 02:00.

   Those use ATC's standard non-user value, -1. This function names it, so the
   constant appears once rather than in ninety INSERT statements, and so the
   grep for "where does -1 come from" has one answer.

   WHY A CONSTANT RATHER THAN A LOOKUP.  It is tempting to read this from a
   settings table so it can be changed without an ALTER. Do not: it is called
   on the capture path, the highest-volume path in the framework, so a version
   that queries a table executes once PER ROW INSERTED. A scalar UDF doing a
   table read on a hot insert path is a well-known way to turn a fast insert
   into a slow one. Returning a constant lets SQL Server inline it to nothing.

   CREATE OR ALTER, not CREATE-if-absent: an environment deployed before this
   change has the old value, and re-running the scripts is how an environment is
   brought up to date. A guarded CREATE would silently leave it stale.
   ============================================================================= */
EXEC (N'
CREATE OR ALTER FUNCTION ERM.fn_SystemUserID()
RETURNS INT
AS
BEGIN
    /* ATC standard non-user / system value. Used where no ERP UserProfileID
       exists - public pages, seed data, scheduled jobs, automatic rules. */
    RETURN -1;
END');
GO

/* --------------------------------------------------- migration history --- */
/* The framework versions its own database objects.  Every script in this
   folder records itself here, so an upgrade can tell exactly which scripts a
   given environment has already had applied.  This is the "how is the
   framework deployed and versioned in the database" answer: plain, ordered,
   idempotent SQL scripts + this ledger, applied by DbUp (or by hand).        */
IF OBJECT_ID(N'ERM.ERM_SchemaVersion', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_SchemaVersion
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_SchemaVersion_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_SchemaVersion_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_SchemaVersion_AppNo DEFAULT (1),
        ScriptName      NVARCHAR(255)   NOT NULL,
        AppliedUtc      DATETIME2(3)    NOT NULL CONSTRAINT DF_SchemaVersion_AppliedUtc DEFAULT (SYSUTCDATETIME()),
        AppliedBy       NVARCHAR(128)   NOT NULL CONSTRAINT DF_SchemaVersion_AppliedBy  DEFAULT (SUSER_SNAME()),
        FrameworkVersion NVARCHAR(32)   NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_SchemaVersion_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_SchemaVersion_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_SchemaVersion_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
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
IF OBJECT_ID(N'ERM.ERM_Severity', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_Severity
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Severity_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_Severity_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_Severity_AppNo DEFAULT (1),
        SeverityID      TINYINT         NOT NULL,
        Code            NVARCHAR(20)    NOT NULL,
        DisplayName     NVARCHAR(50)    NOT NULL,
        RankOrder       TINYINT         NOT NULL,   -- 1 = most severe
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_Severity_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_Severity_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_Severity_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_Severity PRIMARY KEY CLUSTERED (SeverityID),
        CONSTRAINT UQ_Severity_Code UNIQUE (Code)
    );
END
GO

/* ------------------------------------------------------------- category -- */
IF OBJECT_ID(N'ERM.ERM_ErrorCategory', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_ErrorCategory
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_ErrorCategory_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_ErrorCategory_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_ErrorCategory_AppNo DEFAULT (1),
        CategoryID      SMALLINT        NOT NULL,
        Code            NVARCHAR(40)    NOT NULL,
        DisplayName     NVARCHAR(100)   NOT NULL,
        -- Default severity applied when the classifier resolves to this category
        -- and the caller did not specify one explicitly.
        DefaultSeverityID TINYINT       NOT NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_ErrorCategory_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_ErrorCategory_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_ErrorCategory_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_ErrorCategory PRIMARY KEY CLUSTERED (CategoryID),
        CONSTRAINT UQ_ErrorCategory_Code UNIQUE (Code),
        CONSTRAINT FK_ErrorCategory_Severity FOREIGN KEY (DefaultSeverityID)
            REFERENCES ERM.ERM_Severity (SeverityID)
    );
END
GO

/* ---------------------------------------------------------------- layer -- */
IF OBJECT_ID(N'ERM.ERM_AppLayer', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_AppLayer
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_AppLayer_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_AppLayer_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_AppLayer_AppNo DEFAULT (1),
        LayerID         TINYINT         NOT NULL,
        Code            NVARCHAR(30)    NOT NULL,
        DisplayName     NVARCHAR(60)    NOT NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_AppLayer_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_AppLayer_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_AppLayer_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_AppLayer PRIMARY KEY CLUSTERED (LayerID),
        CONSTRAINT UQ_AppLayer_Code UNIQUE (Code)
    );
END
GO

/* -------------------------------------------------------------- statuses -- */
IF OBJECT_ID(N'ERM.ERM_TicketStatus', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_TicketStatus
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_TicketStatus_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_TicketStatus_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_TicketStatus_AppNo DEFAULT (1),
        StatusID        TINYINT         NOT NULL,
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
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_TicketStatus_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_TicketStatus_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_TicketStatus_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_TicketStatus PRIMARY KEY CLUSTERED (StatusID),
        CONSTRAINT UQ_TicketStatus_Code UNIQUE (Code)
    );
END
GO

/* The lifecycle itself is data, not code.  Adding a status or re-wiring the
   workflow is an INSERT here - no redeploy of the API or the Angular app.     */
IF OBJECT_ID(N'ERM.ERM_TicketStatusTransition', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_TicketStatusTransition
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_TicketStatusTransition_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_TicketStatusTransition_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_TicketStatusTransition_AppNo DEFAULT (1),
        FromStatusID    TINYINT         NOT NULL,
        ToStatusID      TINYINT         NOT NULL,
        RequiresComment BIT             NOT NULL CONSTRAINT DF_TST_RequiresComment DEFAULT (0),
        RequiresAssignee BIT            NOT NULL CONSTRAINT DF_TST_RequiresAssignee DEFAULT (0),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_TicketStatusTransition_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_TicketStatusTransition_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_TicketStatusTransition_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_TicketStatusTransition PRIMARY KEY CLUSTERED (FromStatusID, ToStatusID),
        CONSTRAINT FK_TST_From FOREIGN KEY (FromStatusID) REFERENCES ERM.ERM_TicketStatus (StatusID),
        CONSTRAINT FK_TST_To   FOREIGN KEY (ToStatusID)   REFERENCES ERM.ERM_TicketStatus (StatusID)
    );
END
GO

/* ---------------------------------------------------------------- queues -- */
IF OBJECT_ID(N'ERM.ERM_TicketQueue', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_TicketQueue
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_TicketQueue_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_TicketQueue_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_TicketQueue_AppNo DEFAULT (1),
        ERM_TicketQueueID         SMALLINT        IDENTITY(1,1) NOT NULL,
        Code            NVARCHAR(40)    NOT NULL,
        DisplayName     NVARCHAR(100)   NOT NULL,
        -- Optional routing hint: tickets whose error came from this ERP module
        -- land in this queue.  NULL = the catch-all queue.
        ErpModuleMatch  NVARCHAR(100)   NULL,
        IsDefault       BIT             NOT NULL CONSTRAINT DF_TicketQueue_IsDefault DEFAULT (0),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_TicketQueue_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_TicketQueue_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_TicketQueue_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_TicketQueue PRIMARY KEY CLUSTERED (ERM_TicketQueueID),
        CONSTRAINT UQ_TicketQueue_Code UNIQUE (Code)
    );
END
GO

/* ------------------------------------------------------------------ SLA -- */
IF OBJECT_ID(N'ERM.ERM_SlaPolicy', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_SlaPolicy
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_SlaPolicy_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_SlaPolicy_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_SlaPolicy_AppNo DEFAULT (1),
        ERM_SlaPolicyID     SMALLINT        IDENTITY(1,1) NOT NULL,
        SeverityID      TINYINT         NOT NULL,
        ERM_TicketQueueID         SMALLINT        NULL,          -- NULL = applies to all queues
        FirstResponseMinutes INT        NOT NULL,
        ResolutionMinutes    INT        NOT NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_SlaPolicy_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_SlaPolicy_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_SlaPolicy_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_SlaPolicy PRIMARY KEY CLUSTERED (ERM_SlaPolicyID),
        CONSTRAINT FK_SlaPolicy_Severity FOREIGN KEY (SeverityID) REFERENCES ERM.ERM_Severity (SeverityID),
        CONSTRAINT FK_SlaPolicy_Queue    FOREIGN KEY (ERM_TicketQueueID)    REFERENCES ERM.ERM_TicketQueue (ERM_TicketQueueID)
    );
    CREATE UNIQUE INDEX UX_SlaPolicy_Sev_Queue ON ERM.ERM_SlaPolicy (SeverityID, ERM_TicketQueueID)
        WHERE IsActive = 1;
END
GO

/* ------------------------------------------------- generic settings bag -- */
/* Read by the API at startup and cached for [CacheSeconds]; a change here is
   picked up without an application restart.                                   */
IF OBJECT_ID(N'ERM.ERM_Setting', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_Setting
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Setting_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_Setting_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_Setting_AppNo DEFAULT (1),
        SettingKey      NVARCHAR(100)   NOT NULL,
        SettingValue    NVARCHAR(400)   NULL,
        DataType        NVARCHAR(20)    NOT NULL CONSTRAINT DF_Setting_DataType DEFAULT (N'string'),
        Description     NVARCHAR(400)   NULL,
        ModifiedUtc     DATETIME2(3)    NOT NULL CONSTRAINT DF_Setting_ModifiedUtc DEFAULT (SYSUTCDATETIME()),
        ModifiedBy      NVARCHAR(128)   NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_Setting_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_Setting_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_Setting_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_Setting PRIMARY KEY CLUSTERED (SettingKey)
    );
END
GO

/* --------------------------------------------------- auto-ticket rules --- */
/* The brief asks that NOT every captured error becomes a ticket.  Errors are
   always logged; a ticket is created only when (a) the user presses "Report
   issue" in the modal, or (b) one of these rules fires.  A rule is evaluated
   against the freshly written occurrence and its fingerprint's rolling count. */
IF OBJECT_ID(N'ERM.ERM_AutoTicketRule', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_AutoTicketRule
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_AutoTicketRule_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_AutoTicketRule_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_AutoTicketRule_AppNo DEFAULT (1),
        ERM_AutoTicketRuleID          SMALLINT        IDENTITY(1,1) NOT NULL,
        RuleName        NVARCHAR(100)   NOT NULL,
        -- All non-NULL predicates must match (AND).  NULL = "don't care".
        MinSeverityID   TINYINT         NULL,          -- severity at least this severe (RankOrder <=)
        CategoryID      SMALLINT        NULL,
        LayerID         TINYINT         NULL,
        ErpModuleMatch  NVARCHAR(100)   NULL,
        EnvironmentMatch NVARCHAR(40)   NULL,
        -- Threshold: fire once the fingerprint has been seen this many times
        -- within the window.  1 + 0 = "fire on the first occurrence".
        MinOccurrences  INT             NOT NULL CONSTRAINT DF_AutoTicketRule_MinOcc DEFAULT (1),
        WindowMinutes   INT             NOT NULL CONSTRAINT DF_AutoTicketRule_Window DEFAULT (60),
        TargetQueueID   SMALLINT        NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_AutoTicketRule_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_AutoTicketRule_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_AutoTicketRule_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_AutoTicketRule PRIMARY KEY CLUSTERED (ERM_AutoTicketRuleID),
        CONSTRAINT FK_AutoTicketRule_Severity FOREIGN KEY (MinSeverityID) REFERENCES ERM.ERM_Severity (SeverityID),
        CONSTRAINT FK_AutoTicketRule_Category FOREIGN KEY (CategoryID)    REFERENCES ERM.ERM_ErrorCategory (CategoryID),
        CONSTRAINT FK_AutoTicketRule_Layer    FOREIGN KEY (LayerID)       REFERENCES ERM.ERM_AppLayer (LayerID),
        CONSTRAINT FK_AutoTicketRule_Queue    FOREIGN KEY (TargetQueueID) REFERENCES ERM.ERM_TicketQueue (ERM_TicketQueueID)
    );
END
GO

/* ------------------------------------------------------ redaction rules -- */
/* Allow-list, not deny-list.  The capture pipeline keeps ONLY the keys named
   here and replaces every other value with '***'.  A deny-list ("redact
   anything called password") silently leaks the next field somebody invents;
   an allow-list fails closed.                                                 */
IF OBJECT_ID(N'ERM.ERM_RedactionAllowList', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_RedactionAllowList
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_RedactionAllowList_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_RedactionAllowList_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_RedactionAllowList_AppNo DEFAULT (1),
        ERM_RedactionAllowListID     SMALLINT        IDENTITY(1,1) NOT NULL,
        -- Scope: 'header' | 'query' | 'body' | 'cookie' | 'route'
        Scope           NVARCHAR(20)    NOT NULL,
        -- Case-insensitive key that is safe to persist in full.
        KeyName         NVARCHAR(100)   NOT NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_RedactionAllowList_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_RedactionAllowList_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_RedactionAllowList_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_RedactionAllowList PRIMARY KEY CLUSTERED (ERM_RedactionAllowListID),
        CONSTRAINT UQ_Redaction_Scope_Key UNIQUE (Scope, KeyName)
    );
END
GO

/* ------------------------------------------------------ retention policy -- */
IF OBJECT_ID(N'ERM.ERM_RetentionPolicy', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_RetentionPolicy
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_RetentionPolicy_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_RetentionPolicy_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_RetentionPolicy_AppNo DEFAULT (1),
        ERM_RetentionPolicyID        SMALLINT        IDENTITY(1,1) NOT NULL,
        -- Which data set this policy governs.
        -- 'occurrence' | 'occurrence_detail' | 'ticket' | 'audit'
        DataSet         NVARCHAR(40)    NOT NULL,
        -- Rows older than this move to the *_Archive table.  0 = never archive.
        ArchiveAfterDays INT            NOT NULL,
        -- Rows older than this are deleted from the archive.  0 = keep forever.
        PurgeAfterDays  INT             NOT NULL,
        -- Batch size per delete/insert loop, so the job never takes a long lock.
        BatchSize       INT             NOT NULL CONSTRAINT DF_RetentionPolicy_Batch DEFAULT (5000),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_RetentionPolicy_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_RetentionPolicy_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_RetentionPolicy_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_RetentionPolicy PRIMARY KEY CLUSTERED (ERM_RetentionPolicyID),
        CONSTRAINT UQ_RetentionPolicy_DataSet UNIQUE (DataSet)
    );
END
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'001_schema_and_config.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.0.0', ERM.fn_SystemUserID());
GO
