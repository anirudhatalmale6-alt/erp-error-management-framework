/* =============================================================================
   ERP Error Management Framework - RUN_ALL
   -----------------------------------------------------------------------------
   Every required script, in order, in one file. Paste into SSMS against the
   LinkedScam TEST database and press Execute.

   It is the SAME TEN SCRIPTS concatenated - nothing here is unique to this
   file, so if you would rather run them one at a time you will get an identical
   result. This exists only so the whole install is one paste.

   BEFORE YOU RUN
     * Check you are on the TEST database, not EBS-PROD. This script creates
       objects; it reads and alters nothing outside its own [ERM] schema.
     * Open 006_security.sql's section below and set @AppUser to your
       application login, or leave it and grant EXECUTE later.

   NOT INCLUDED, deliberately: 008 and 009. Both are optional add-ons and
   neither should go into Test on day one - see db/README.md.

   Idempotent: safe to re-run. Re-running is how you apply an update.

   After it finishes, run VERIFY.sql and send me its output.
   ============================================================================= */
SET NOCOUNT ON;
GO
PRINT '=== ERM install starting ===';
GO

/* ==========================================================================
   SCRIPT: 001_schema_and_config.sql
   ========================================================================== */
GO
PRINT '--- 001_schema_and_config.sql ---';
GO

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

GO

/* ==========================================================================
   SCRIPT: 002_core_tables.sql
   ========================================================================== */
GO
PRINT '--- 002_core_tables.sql ---';
GO

/* =============================================================================
   ERP Error Management Framework
   Script 002 - Core tables: fingerprints, occurrences, tickets, audit trail
   Idempotent: yes
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =============================================================================
   REFERENCE CODE GENERATION - LinkedScam standard
   -----------------------------------------------------------------------------
        Ticket:  LS-ERM-TKT-YYMMDD-X
        Error:   LS-ERM-ERR-YYMMDD-X

   X restarts at 1 whenever the date changes, and the ticket and error counters
   are independent.

   WHY THIS IS NOT A SEQUENCE
   --------------------------
   The previous implementation used a SQL Server SEQUENCE. A sequence is ideal
   for a monotonic number - but it cannot reset daily, so it cannot produce this
   format at all.

   WHY IT IS NOT SELECT MAX(...) + 1
   ---------------------------------
   The obvious replacement is to read the highest counter for today and add one.
   That is a read followed by a write, and two sessions doing it at the same
   moment both read the same value and both write the same reference. Under
   NOLOCK-ish default isolation this is not a rare race: error capture is
   bursty by nature - one bad deployment produces hundreds of errors in the same
   second, from different users, across several application instances. This is
   exactly the case the standard's point 7 calls out.

   WHAT THIS DOES INSTEAD
   ----------------------
   One row per (type, date) holding the last value used, and a SINGLE atomic
   UPDATE that increments and returns the new value in the same statement:

       UPDATE ... SET LastValue = LastValue + 1
       OUTPUT inserted.LastValue INTO @claimed
       WHERE RefType = @t AND RefDate = @d;

   The UPDATE takes an exclusive lock on the row for its duration, so two
   concurrent callers are serialised by the engine and each receives a distinct
   value. There is no window between reading and writing, because there is no
   read.

   The only remaining race is the FIRST reference of a given day, when the row
   does not exist yet and two sessions both try to create it. That is settled by
   the primary key: one INSERT wins, the loser catches the duplicate-key error
   and re-runs the UPDATE, which now finds the row. A retry loop is used rather
   than SERIALIZABLE + MERGE because MERGE under concurrency has its own
   well-documented deadlock behaviour, and this path executes at most once per
   type per day.

   The uniqueness is therefore guaranteed by the database, not by application
   timing - which is what the standard requires.
   ============================================================================= */

IF OBJECT_ID(N'ERM.ERM_ReferenceCounter', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_ReferenceCounter
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_ReferenceCounter_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_ReferenceCounter_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_ReferenceCounter_AppNo DEFAULT (1),

        ERM_ReferenceCounterID INT      IDENTITY(1,1) NOT NULL,
        /* 'TKT' or 'ERR'. CHAR(3) because the standard fixes both at three. */
        RefType       CHAR(3)          NOT NULL,
        /* DATE, not DATETIME: the counter is per calendar day and a time
           component would silently create a new counter every millisecond. */
        RefDate       DATE             NOT NULL,
        LastValue     INT              NOT NULL CONSTRAINT DF_ReferenceCounter_Last DEFAULT (0),

        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_ReferenceCounter_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_ReferenceCounter_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_ReferenceCounter_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,

        CONSTRAINT PK_ReferenceCounter PRIMARY KEY CLUSTERED (RefType, RefDate),
        CONSTRAINT UQ_ReferenceCounter_ID UNIQUE (ERM_ReferenceCounterID)
    );
END
GO

/* -----------------------------------------------------------------------------
   usp_NextReference
   -----------------------------------------------------------------------------
   Returns the next reference for a type, formatted to the standard.

   Called from inside the capture and ticket transactions. It deliberately does
   NOT open its own transaction: it must enlist in the caller's, so that a
   rolled-back capture does not leave a consumed counter value behind. Gaps
   would not break anything, but they would make the numbers confusing to audit.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_NextReference
(
    @RefType   CHAR(3),            -- 'TKT' | 'ERR'
    @Reference VARCHAR(30) OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RefType NOT IN ('TKT', 'ERR')
    BEGIN
        RAISERROR (N'Reference type must be TKT or ERR.', 16, 1);
        RETURN;
    END

    /* The date the reference is stamped with. GETUTCDATE() to match the
       LinkedScam UTC standard - using local time would make the counter reset
       at a different moment than every timestamp in the schema, and produce
       two references numbered -1 on the same calendar day at the boundary. */
    DECLARE @Today DATE = CONVERT(DATE, GETUTCDATE());
    DECLARE @Claimed TABLE (Value INT);
    DECLARE @Next INT = NULL;
    DECLARE @Attempt INT = 0;

    WHILE @Next IS NULL AND @Attempt < 3
    BEGIN
        SET @Attempt += 1;

        DELETE @Claimed;

        /* Single atomic statement: increment and return, no read-then-write
           window for a concurrent session to slip into. */
        UPDATE ERM.ERM_ReferenceCounter
           SET LastValue   = LastValue + 1,
               UpdatedDate = GETUTCDATE()
        OUTPUT inserted.LastValue INTO @Claimed (Value)
         WHERE RefType = @RefType
           AND RefDate = @Today;

        SELECT @Next = Value FROM @Claimed;

        IF @Next IS NULL
        BEGIN
            /* First reference of the day for this type. Two sessions can reach
               here together; the primary key decides which one creates the row
               and the other loops round to the UPDATE above. */
            BEGIN TRY
                INSERT ERM.ERM_ReferenceCounter (RefType, RefDate, LastValue, CreatedBy)
                VALUES (@RefType, @Today, 1, ERM.fn_SystemUserID());

                SET @Next = 1;
            END TRY
            BEGIN CATCH
                /* 2627/2601 = duplicate key: somebody else created it a
                   microsecond ago, which is success as far as we are concerned.
                   Anything else is a real failure and must surface. */
                IF ERROR_NUMBER() NOT IN (2627, 2601) THROW;
            END CATCH
        END
    END

    IF @Next IS NULL
    BEGIN
        RAISERROR (N'Could not allocate a reference number after 3 attempts.', 16, 1);
        RETURN;
    END

    /* LS-ERM-TKT-260903-1
       The counter is NOT zero-padded: the standard's examples show -1, -2, -3,
       and padding them to -0001 would not match. */
    SET @Reference = 'LS-ERM-' + @RefType + '-'
                   + FORMAT(@Today, 'yyMMdd') + '-'
                   + CONVERT(VARCHAR(10), @Next);
END
GO

/* =============================================================================
   ErrorFingerprint - one row per DISTINCT problem
   -----------------------------------------------------------------------------
   This is the deduplication anchor.  The hash is computed in the capture
   library (same algorithm in TypeScript and C#, see docs/ARCHITECTURE.md §6) from
   the NORMALISED error, so the 4,000 occurrences of one broken LOV collapse to
   a single row here with OccurrenceCount = 4000 - and to at most one open
   ticket, not 4,000 tickets.
   ============================================================================= */
IF OBJECT_ID(N'ERM.ERM_ErrorFingerprint', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_ErrorFingerprint
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_ErrorFingerprint_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_ErrorFingerprint_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_ErrorFingerprint_AppNo DEFAULT (1),
        ERM_ErrorFingerprintID       BIGINT          IDENTITY(1,1) NOT NULL,
        -- SHA-256 of the normalised signature, lower-case hex, 64 chars.
        FingerprintHash     CHAR(64)        NOT NULL,
        -- The human-readable signature the hash was taken over, kept so an
        -- admin can see WHY two errors were considered the same.
        SignatureText       NVARCHAR(1000)  NOT NULL,

        LayerID             TINYINT         NOT NULL,
        CategoryID          SMALLINT        NOT NULL,
        SeverityID          TINYINT         NOT NULL,

        ExceptionType       NVARCHAR(400)   NULL,
        -- Message with volatile parts (ids, guids, numbers, quoted literals,
        -- timestamps) already replaced by placeholders.
        NormalizedMessage   NVARCHAR(2000)  NULL,

        ErpModule           NVARCHAR(100)   NULL,
        Screen              NVARCHAR(200)   NULL,
        Component           NVARCHAR(200)   NULL,
        ApiEndpoint         NVARCHAR(400)   NULL,
        SqlObjectName       NVARCHAR(256)   NULL,

        FirstSeenUtc        DATETIME2(3)    NOT NULL,
        LastSeenUtc         DATETIME2(3)    NOT NULL,
        OccurrenceCount     BIGINT          NOT NULL CONSTRAINT DF_Fingerprint_Count DEFAULT (0),
        DistinctUserCount   INT             NOT NULL CONSTRAINT DF_Fingerprint_Users DEFAULT (0),

        -- Triage state of the PROBLEM (distinct from any ticket's state).
        -- 'new' | 'acknowledged' | 'known_issue' | 'muted' | 'resolved'
        TriageState         NVARCHAR(20)    NOT NULL CONSTRAINT DF_Fingerprint_Triage DEFAULT (N'new'),
        -- While muted, occurrences are still counted but no auto-ticket fires
        -- and the user-facing modal can be downgraded to a toast.
        MutedUntilUtc       DATETIME2(3)    NULL,
        -- The currently open ticket for this problem, if any.  Set by
        -- usp_Ticket_Create; cleared when that ticket reaches a terminal status.
        OpenTicketID        BIGINT          NULL,
        Notes               NVARCHAR(MAX)   NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_ErrorFingerprint_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_ErrorFingerprint_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_ErrorFingerprint_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_ErrorFingerprint PRIMARY KEY CLUSTERED (ERM_ErrorFingerprintID),
        CONSTRAINT UQ_ErrorFingerprint_Hash UNIQUE (FingerprintHash),
        CONSTRAINT FK_Fingerprint_Layer    FOREIGN KEY (LayerID)    REFERENCES ERM.ERM_AppLayer (LayerID),
        CONSTRAINT FK_Fingerprint_Category FOREIGN KEY (CategoryID) REFERENCES ERM.ERM_ErrorCategory (CategoryID),
        CONSTRAINT FK_Fingerprint_Severity FOREIGN KEY (SeverityID) REFERENCES ERM.ERM_Severity (SeverityID)
    );

    CREATE INDEX IX_Fingerprint_LastSeen  ON ERM.ERM_ErrorFingerprint (LastSeenUtc DESC) INCLUDE (OccurrenceCount, SeverityID, TriageState);
    CREATE INDEX IX_Fingerprint_Module    ON ERM.ERM_ErrorFingerprint (ErpModule, LastSeenUtc DESC);
    CREATE INDEX IX_Fingerprint_Triage    ON ERM.ERM_ErrorFingerprint (TriageState, SeverityID) INCLUDE (LastSeenUtc, OccurrenceCount);
END
GO

/* =============================================================================
   ErrorOccurrence - one row per ERROR EVENT (the searchable, narrow table)
   -----------------------------------------------------------------------------
   Deliberately free of NVARCHAR(MAX) columns: this is the table the admin
   console filters, counts and charts, and the one that grows fastest.  The
   heavy payload lives 1:1 in ErrorOccurrenceDetail so retention can drop
   payloads early while keeping the trend data.
   ============================================================================= */
IF OBJECT_ID(N'ERM.ERM_ErrorOccurrence', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_ErrorOccurrence
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_ErrorOccurrence_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_ErrorOccurrence_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_ErrorOccurrence_AppNo DEFAULT (1),
        ERM_ErrorOccurrenceID        BIGINT          IDENTITY(1,1) NOT NULL,
        -- Shown to the user in the modal, e.g. 'LS-ERM-ERR-260903-2'.
        ErrorReference      VARCHAR(30)     NOT NULL,
        ERM_ErrorFingerprintID       BIGINT          NOT NULL,

        /* ---- when ---- */
        OccurredUtc         DATETIME2(3)    NOT NULL,
        -- Client wall-clock + offset, kept separately: a user report says
        -- "it broke at 2pm" and 2pm is local, not UTC.
        OccurredLocal       DATETIME2(3)    NULL,
        ClientUtcOffsetMin  SMALLINT        NULL,
        ReceivedUtc         DATETIME2(3)    NOT NULL CONSTRAINT DF_Occurrence_Received DEFAULT (SYSUTCDATETIME()),

        /* ---- what ---- */
        LayerID             TINYINT         NOT NULL,
        CategoryID          SMALLINT        NOT NULL,
        SeverityID          TINYINT         NOT NULL,
        ExceptionType       NVARCHAR(400)   NULL,
        -- Raw (still redacted) message, unlike the fingerprint's normalised one.
        Message             NVARCHAR(2000)  NULL,

        /* ---- where: front end ---- */
        ErpModule           NVARCHAR(100)   NULL,
        Screen              NVARCHAR(200)   NULL,
        RouteUrl            NVARCHAR(500)   NULL,
        Component           NVARCHAR(200)   NULL,
        -- For form/validation and button/submit errors.
        ActionName          NVARCHAR(200)   NULL,
        FormName            NVARCHAR(200)   NULL,
        LovName             NVARCHAR(200)   NULL,

        /* ---- where: API ---- */
        ApiApplication      NVARCHAR(100)   NULL,
        ApiController       NVARCHAR(200)   NULL,
        ApiAction           NVARCHAR(200)   NULL,
        ApiEndpoint         NVARCHAR(400)   NULL,
        HttpMethod          VARCHAR(10)     NULL,
        HttpStatusCode      SMALLINT        NULL,
        DurationMs          INT             NULL,

        /* ---- where: database ---- */
        SqlErrorNumber      INT             NULL,
        SqlErrorSeverity    TINYINT         NULL,
        SqlErrorState       TINYINT         NULL,
        SqlObjectName       NVARCHAR(256)   NULL,   -- procedure / function / trigger
        SqlLineNumber       INT             NULL,
        SqlServerName       NVARCHAR(128)   NULL,
        SqlDatabaseName     NVARCHAR(128)   NULL,
        SqlSchemaName       NVARCHAR(128)   NULL,

        /* ---- who ----
           UserProfileID is the ERP's OWN integer user key - the value
           generic_service.GetUserProfileKey() returns in Angular, and the value
           the ERP APIs and procedures already receive as CreatedBy / UpdatedBy
           / UserProfileID.  The framework deliberately does not mint or map an
           identifier of its own: a second user id is a second thing to keep in
           step, and it would be wrong exactly when it mattered.
           -1 = no ERP user (public page, scheduled job, automatic rule).
           UserName is display text.  Never join or filter on it. */
        UserProfileID       INT             NOT NULL,
        UserName            NVARCHAR(200)   NULL,
        UserDisplayName     NVARCHAR(200)   NULL,
        TenantID            NVARCHAR(64)    NULL,
        SessionID           NVARCHAR(100)   NULL,
        ClientIp            NVARCHAR(64)    NULL,

        /* ---- correlation ---- */
        -- Generated in the browser, forwarded on every hop, so an Angular
        -- error, its HTTP failure, the .NET exception and the SQL error all
        -- carry the same value and can be assembled into one incident view.
        CorrelationID       UNIQUEIDENTIFIER NOT NULL,
        -- Identifies this single HTTP request within the correlation.
        RequestID           UNIQUEIDENTIFIER NULL,
        -- Set when this occurrence was raised as a direct consequence of
        -- another (e.g. the Angular HTTP error whose cause is the .NET one).
        ParentOccurrenceID  BIGINT          NULL,

        /* ---- environment / client ---- */
        Environment         NVARCHAR(40)    NOT NULL,
        AppVersion          NVARCHAR(60)    NULL,
        MachineName         NVARCHAR(128)   NULL,
        BrowserName         NVARCHAR(60)    NULL,
        BrowserVersion      NVARCHAR(40)    NULL,
        OsName              NVARCHAR(60)    NULL,
        DeviceType          NVARCHAR(30)    NULL,
        ScreenResolution    VARCHAR(20)     NULL,
        Locale              NVARCHAR(20)    NULL,

        /* ---- outcome ---- */
        -- Was the user actually shown the modal for this one?
        WasUserNotified     BIT             NOT NULL CONSTRAINT DF_Occurrence_Notified DEFAULT (0),
        -- Populated when a ticket is raised from this occurrence.
        ERM_TicketID            BIGINT          NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_ErrorOccurrence_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_ErrorOccurrence_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_ErrorOccurrence_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_ErrorOccurrence PRIMARY KEY CLUSTERED (ERM_ErrorOccurrenceID),
        CONSTRAINT UQ_ErrorOccurrence_Reference UNIQUE (ErrorReference),
        CONSTRAINT FK_Occurrence_Fingerprint FOREIGN KEY (ERM_ErrorFingerprintID) REFERENCES ERM.ERM_ErrorFingerprint (ERM_ErrorFingerprintID),
        CONSTRAINT FK_Occurrence_Layer       FOREIGN KEY (LayerID)       REFERENCES ERM.ERM_AppLayer (LayerID),
        CONSTRAINT FK_Occurrence_Category    FOREIGN KEY (CategoryID)    REFERENCES ERM.ERM_ErrorCategory (CategoryID),
        CONSTRAINT FK_Occurrence_Severity    FOREIGN KEY (SeverityID)    REFERENCES ERM.ERM_Severity (SeverityID),
        CONSTRAINT FK_Occurrence_Parent      FOREIGN KEY (ParentOccurrenceID) REFERENCES ERM.ERM_ErrorOccurrence (ERM_ErrorOccurrenceID)
    );

    CREATE INDEX IX_Occurrence_OccurredUtc  ON ERM.ERM_ErrorOccurrence (OccurredUtc DESC)
        INCLUDE (ERM_ErrorFingerprintID, SeverityID, LayerID, ErpModule, UserProfileID, UserName, ERM_TicketID);
    CREATE INDEX IX_Occurrence_Fingerprint  ON ERM.ERM_ErrorOccurrence (ERM_ErrorFingerprintID, OccurredUtc DESC);
    CREATE INDEX IX_Occurrence_Correlation  ON ERM.ERM_ErrorOccurrence (CorrelationID, OccurredUtc);
    CREATE INDEX IX_Occurrence_User         ON ERM.ERM_ErrorOccurrence (UserProfileID, OccurredUtc DESC);
    CREATE INDEX IX_Occurrence_Module       ON ERM.ERM_ErrorOccurrence (ErpModule, Screen, OccurredUtc DESC);
    CREATE INDEX IX_Occurrence_Api          ON ERM.ERM_ErrorOccurrence (ApiController, ApiAction, OccurredUtc DESC);
    CREATE INDEX IX_Occurrence_Sql          ON ERM.ERM_ErrorOccurrence (SqlErrorNumber, OccurredUtc DESC) WHERE SqlErrorNumber IS NOT NULL;
    CREATE INDEX IX_Occurrence_Ticket       ON ERM.ERM_ErrorOccurrence (ERM_TicketID) WHERE ERM_TicketID IS NOT NULL;
END
GO

/* =============================================================================
   ErrorOccurrenceDetail - the heavy 1:1 payload
   ============================================================================= */
IF OBJECT_ID(N'ERM.ERM_ErrorOccurrenceDetail', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_ErrorOccurrenceDetail
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_ErrorOccurrenceDetail_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_ErrorOccurrenceDetail_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_ErrorOccurrenceDetail_AppNo DEFAULT (1),
        ERM_ErrorOccurrenceID        BIGINT          NOT NULL,
        StackTrace          NVARCHAR(MAX)   NULL,
        -- Full inner-exception chain, outermost first, already flattened.
        InnerExceptionChain NVARCHAR(MAX)   NULL,
        -- JSON: { "url", "method", "headers": {...}, "query": {...}, "body": ... }
        -- with every non-allow-listed value replaced by '***'.
        RequestPayloadJson  NVARCHAR(MAX)   NULL,
        ResponsePayloadJson NVARCHAR(MAX)   NULL,
        -- JSON array of the control names that failed validation and the rule
        -- that failed - never the values the user typed.
        ValidationErrorsJson NVARCHAR(MAX)  NULL,
        -- Ring buffer of the last N user actions before the error (route
        -- changes, button ids, http calls).  Redacted the same way.
        BreadcrumbsJson     NVARCHAR(MAX)   NULL,
        -- Anything module-specific the caller wants to attach.
        CustomDataJson      NVARCHAR(MAX)   NULL,
        SqlStatementText    NVARCHAR(MAX)   NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_ErrorOccurrenceDetail_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_ErrorOccurrenceDetail_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_ErrorOccurrenceDetail_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_ErrorOccurrenceDetail PRIMARY KEY CLUSTERED (ERM_ErrorOccurrenceID),
        CONSTRAINT FK_OccurrenceDetail_Occurrence FOREIGN KEY (ERM_ErrorOccurrenceID)
            REFERENCES ERM.ERM_ErrorOccurrence (ERM_ErrorOccurrenceID) ON DELETE CASCADE
    );
END
GO

/* =============================================================================
   Ticket
   ============================================================================= */
IF OBJECT_ID(N'ERM.ERM_Ticket', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_Ticket
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Ticket_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_Ticket_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_Ticket_AppNo DEFAULT (1),
        ERM_TicketID            BIGINT          IDENTITY(1,1) NOT NULL,
        TicketNumber        VARCHAR(30)     NOT NULL,      -- 'LS-ERM-TKT-260903-4'

        -- The occurrence the user was looking at when they pressed Report.
        ERM_ErrorOccurrenceID        BIGINT          NULL,
        -- The problem.  Repeat reports of the same problem attach here.
        ERM_ErrorFingerprintID       BIGINT          NOT NULL,

        StatusID            TINYINT         NOT NULL,
        SeverityID          TINYINT         NOT NULL,
        ERM_TicketQueueID             SMALLINT        NOT NULL,
        ERM_SlaPolicyID         SMALLINT        NULL,

        Title               NVARCHAR(400)   NOT NULL,
        -- What the user typed in the modal, if anything.
        UserDescription     NVARCHAR(MAX)   NULL,

        -- The reporter's ERP UserProfileID.  This is what "my tickets" and
        -- every ownership check key off; -1 means it was raised without a
        -- signed-in user behind it.
        ReportedByUserProfileID INT         NOT NULL,
        ReportedByUserName  NVARCHAR(200)   NULL,
        -- 'user' | 'auto_rule' | 'admin'
        CreatedVia          NVARCHAR(20)    NOT NULL CONSTRAINT DF_Ticket_CreatedVia DEFAULT (N'user'),
        -- NULL, not -1: unassigned is a real and different state from
        -- "assigned to nobody in particular", and the queue view depends on
        -- being able to tell them apart.
        AssignedToUserProfileID INT         NULL,
        AssignedToUserName  NVARCHAR(200)   NULL,

        ErpModule           NVARCHAR(100)   NULL,
        Environment         NVARCHAR(40)    NULL,

        /* ---- lifecycle timestamps: every one the brief listed ---- */
        CreatedUtc          DATETIME2(3)    NOT NULL CONSTRAINT DF_Ticket_CreatedUtc DEFAULT (SYSUTCDATETIME()),
        FirstResponseUtc    DATETIME2(3)    NULL,
        AssignedUtc         DATETIME2(3)    NULL,
        ResolvedUtc         DATETIME2(3)    NULL,
        ClosedUtc           DATETIME2(3)    NULL,
        LastStatusChangeUtc DATETIME2(3)    NOT NULL CONSTRAINT DF_Ticket_LastChange DEFAULT (SYSUTCDATETIME()),

        /* ---- metrics, maintained by usp_Ticket_ChangeStatus ---- */
        -- Wall-clock minutes from creation to closure (or to now, if open):
        -- persisted at closure so reports do not have to re-derive history.
        TotalElapsedMinutes     INT         NULL,
        -- Elapsed minus every minute spent in a status flagged IsPaused.
        ActiveProcessingMinutes INT         NULL,
        SlaFirstResponseBreached BIT        NOT NULL CONSTRAINT DF_Ticket_SlaFrBreach DEFAULT (0),
        SlaResolutionBreached    BIT        NOT NULL CONSTRAINT DF_Ticket_SlaResBreach DEFAULT (0),
        ReopenCount             INT         NOT NULL CONSTRAINT DF_Ticket_Reopen DEFAULT (0),
        -- How many further occurrences of this fingerprint arrived while the
        -- ticket was open.  This is the "how bad is it really" number.
        LinkedOccurrenceCount   INT         NOT NULL CONSTRAINT DF_Ticket_LinkedOcc DEFAULT (1),

        ResolutionCode      NVARCHAR(60)    NULL,
        ResolutionNotes     NVARCHAR(MAX)   NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_Ticket_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_Ticket_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_Ticket_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_Ticket PRIMARY KEY CLUSTERED (ERM_TicketID),
        CONSTRAINT UQ_Ticket_Number UNIQUE (TicketNumber),
        CONSTRAINT FK_Ticket_Occurrence  FOREIGN KEY (ERM_ErrorOccurrenceID)  REFERENCES ERM.ERM_ErrorOccurrence (ERM_ErrorOccurrenceID),
        CONSTRAINT FK_Ticket_Fingerprint FOREIGN KEY (ERM_ErrorFingerprintID) REFERENCES ERM.ERM_ErrorFingerprint (ERM_ErrorFingerprintID),
        CONSTRAINT FK_Ticket_Status      FOREIGN KEY (StatusID)      REFERENCES ERM.ERM_TicketStatus (StatusID),
        CONSTRAINT FK_Ticket_Severity    FOREIGN KEY (SeverityID)    REFERENCES ERM.ERM_Severity (SeverityID),
        CONSTRAINT FK_Ticket_Queue       FOREIGN KEY (ERM_TicketQueueID)       REFERENCES ERM.ERM_TicketQueue (ERM_TicketQueueID),
        CONSTRAINT FK_Ticket_Sla         FOREIGN KEY (ERM_SlaPolicyID)   REFERENCES ERM.ERM_SlaPolicy (ERM_SlaPolicyID)
    );

    CREATE INDEX IX_Ticket_Status      ON ERM.ERM_Ticket (StatusID, CreatedUtc DESC) INCLUDE (ERM_TicketQueueID, SeverityID, AssignedToUserProfileID, AssignedToUserName);
    CREATE INDEX IX_Ticket_Queue       ON ERM.ERM_Ticket (ERM_TicketQueueID, StatusID, CreatedUtc DESC);
    CREATE INDEX IX_Ticket_Reporter    ON ERM.ERM_Ticket (ReportedByUserProfileID, CreatedUtc DESC);
    CREATE INDEX IX_Ticket_Assignee    ON ERM.ERM_Ticket (AssignedToUserProfileID, StatusID);
    CREATE INDEX IX_Ticket_Fingerprint ON ERM.ERM_Ticket (ERM_ErrorFingerprintID, StatusID);
END
GO

/* FK from occurrence -> ticket added after Ticket exists (circular reference). */
IF OBJECT_ID(N'ERM.ERM_Ticket', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Occurrence_Ticket')
    ALTER TABLE ERM.ERM_ErrorOccurrence WITH CHECK
        ADD CONSTRAINT FK_Occurrence_Ticket FOREIGN KEY (ERM_TicketID) REFERENCES ERM.ERM_Ticket (ERM_TicketID);
GO
IF OBJECT_ID(N'ERM.ERM_Ticket', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Fingerprint_OpenTicket')
    ALTER TABLE ERM.ERM_ErrorFingerprint WITH CHECK
        ADD CONSTRAINT FK_Fingerprint_OpenTicket FOREIGN KEY (OpenTicketID) REFERENCES ERM.ERM_Ticket (ERM_TicketID);
GO

/* =============================================================================
   TicketStatusHistory - the audit trail the brief specified, verbatim
   ============================================================================= */
IF OBJECT_ID(N'ERM.ERM_TicketStatusHistory', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_TicketStatusHistory
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_TicketStatusHistory_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_TicketStatusHistory_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_TicketStatusHistory_AppNo DEFAULT (1),
        ERM_TicketStatusHistoryID           BIGINT          IDENTITY(1,1) NOT NULL,
        ERM_TicketID            BIGINT          NOT NULL,
        SequenceNo          INT             NOT NULL,      -- 1-based, gapless per ticket
        FromStatusID        TINYINT         NULL,          -- NULL on creation
        ToStatusID          TINYINT         NOT NULL,
        ChangedByUserProfileID INT          NOT NULL,
        ChangedByUserName   NVARCHAR(200)   NULL,
        ChangedUtc          DATETIME2(3)    NOT NULL CONSTRAINT DF_TSH_ChangedUtc DEFAULT (SYSUTCDATETIME()),
        -- Minutes the ticket spent in FromStatusID before this change.  This is
        -- the column that answers "time spent in each status" without a window
        -- function over the whole history at report time.
        MinutesInFromStatus INT             NULL,
        Comments            NVARCHAR(MAX)   NULL,
        -- Visible to the end user, or internal-only?
        IsCustomerVisible   BIT             NOT NULL CONSTRAINT DF_TSH_Visible DEFAULT (1),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_TicketStatusHistory_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_TicketStatusHistory_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_TicketStatusHistory_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_TicketStatusHistory PRIMARY KEY CLUSTERED (ERM_TicketID, SequenceNo),
        CONSTRAINT UQ_TicketStatusHistory_Id UNIQUE (ERM_TicketStatusHistoryID),
        CONSTRAINT FK_TSH_Ticket FOREIGN KEY (ERM_TicketID) REFERENCES ERM.ERM_Ticket (ERM_TicketID) ON DELETE CASCADE,
        CONSTRAINT FK_TSH_From   FOREIGN KEY (FromStatusID) REFERENCES ERM.ERM_TicketStatus (StatusID),
        CONSTRAINT FK_TSH_To     FOREIGN KEY (ToStatusID)   REFERENCES ERM.ERM_TicketStatus (StatusID)
    );
    CREATE INDEX IX_TSH_ChangedUtc ON ERM.ERM_TicketStatusHistory (ChangedUtc DESC);
END
GO

/* Free-text conversation on a ticket, separate from status changes so the
   history stays a clean state machine log.                                    */
IF OBJECT_ID(N'ERM.ERM_TicketComment', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_TicketComment
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_TicketComment_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_TicketComment_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_TicketComment_AppNo DEFAULT (1),
        ERM_TicketCommentID           BIGINT          IDENTITY(1,1) NOT NULL,
        ERM_TicketID            BIGINT          NOT NULL,
        AuthorUserProfileID INT             NOT NULL,
        AuthorUserName      NVARCHAR(200)   NULL,
        -- 'reporter' | 'support' | 'system'
        AuthorRole          NVARCHAR(20)    NOT NULL CONSTRAINT DF_TC_Role DEFAULT (N'support'),
        CommentText         NVARCHAR(MAX)   NOT NULL,
        IsCustomerVisible   BIT             NOT NULL CONSTRAINT DF_TC_Visible DEFAULT (1),
        CreatedUtc          DATETIME2(3)    NOT NULL CONSTRAINT DF_TC_CreatedUtc DEFAULT (SYSUTCDATETIME()),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_TicketComment_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_TicketComment_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_TicketComment_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_TicketComment PRIMARY KEY CLUSTERED (ERM_TicketCommentID),
        CONSTRAINT FK_TC_Ticket FOREIGN KEY (ERM_TicketID) REFERENCES ERM.ERM_Ticket (ERM_TicketID) ON DELETE CASCADE
    );
    CREATE INDEX IX_TC_Ticket ON ERM.ERM_TicketComment (ERM_TicketID, CreatedUtc);
END
GO

/* Links every additional occurrence that arrived while a ticket was open, so
   "this ticket represents 812 failures across 43 users" is a query, not a
   guess.                                                                       */
IF OBJECT_ID(N'ERM.ERM_TicketOccurrenceLink', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_TicketOccurrenceLink
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_TicketOccurrenceLink_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_TicketOccurrenceLink_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_TicketOccurrenceLink_AppNo DEFAULT (1),
        ERM_TicketID        BIGINT          NOT NULL,
        ERM_ErrorOccurrenceID    BIGINT          NOT NULL,
        LinkedUtc       DATETIME2(3)    NOT NULL CONSTRAINT DF_TOL_LinkedUtc DEFAULT (SYSUTCDATETIME()),
        -- 'primary' (the one the user reported) | 'deduplicated' | 'manual'
        LinkReason      NVARCHAR(20)    NOT NULL CONSTRAINT DF_TOL_Reason DEFAULT (N'deduplicated'),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_TicketOccurrenceLink_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_TicketOccurrenceLink_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_TicketOccurrenceLink_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_TicketOccurrenceLink PRIMARY KEY CLUSTERED (ERM_TicketID, ERM_ErrorOccurrenceID),
        CONSTRAINT FK_TOL_Ticket     FOREIGN KEY (ERM_TicketID)     REFERENCES ERM.ERM_Ticket (ERM_TicketID) ON DELETE CASCADE,
        CONSTRAINT FK_TOL_Occurrence FOREIGN KEY (ERM_ErrorOccurrenceID) REFERENCES ERM.ERM_ErrorOccurrence (ERM_ErrorOccurrenceID)
    );
    CREATE INDEX IX_TOL_Occurrence ON ERM.ERM_TicketOccurrenceLink (ERM_ErrorOccurrenceID);
END
GO

/* =============================================================================
   Framework self-audit
   -----------------------------------------------------------------------------
   Who changed a configuration row, and when.  Kept deliberately generic.
   ============================================================================= */
IF OBJECT_ID(N'ERM.ERM_ConfigAudit', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_ConfigAudit
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_ConfigAudit_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_ConfigAudit_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_ConfigAudit_AppNo DEFAULT (1),
        ERM_ConfigAuditID         BIGINT          IDENTITY(1,1) NOT NULL,
        TableName       NVARCHAR(128)   NOT NULL,
        KeyValue        NVARCHAR(200)   NOT NULL,
        Operation       VARCHAR(10)     NOT NULL,     -- INSERT | UPDATE | DELETE
        OldValuesJson   NVARCHAR(MAX)   NULL,
        NewValuesJson   NVARCHAR(MAX)   NULL,
        ChangedByUserProfileID INT      NOT NULL,
        ChangedByUserName NVARCHAR(200) NULL,
        ChangedUtc      DATETIME2(3)    NOT NULL CONSTRAINT DF_ConfigAudit_ChangedUtc DEFAULT (SYSUTCDATETIME()),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_ConfigAudit_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_ConfigAudit_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_ConfigAudit_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_ConfigAudit PRIMARY KEY CLUSTERED (ERM_ConfigAuditID)
    );
    CREATE INDEX IX_ConfigAudit_Table ON ERM.ERM_ConfigAudit (TableName, ChangedUtc DESC);
END
GO

/* =============================================================================
   DeadLetter - the framework's own failure log
   -----------------------------------------------------------------------------
   "The error-management framework must not interrupt the ERP if an
   error-management operation fails."  When the capture pipeline itself throws
   (bad payload, deadlock, schema drift), the raw envelope lands here instead of
   bubbling up.  Nothing reads this table at runtime; it exists so a silent
   capture failure is still discoverable.
   ============================================================================= */
IF OBJECT_ID(N'ERM.ERM_DeadLetter', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_DeadLetter
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_DeadLetter_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_DeadLetter_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_DeadLetter_AppNo DEFAULT (1),
        ERM_DeadLetterID    BIGINT          IDENTITY(1,1) NOT NULL,
        ReceivedUtc     DATETIME2(3)    NOT NULL CONSTRAINT DF_DeadLetter_Received DEFAULT (SYSUTCDATETIME()),
        Source          NVARCHAR(60)    NULL,          -- 'angular' | 'webapi2' | 'aspnetcore' | 'sql'
        RawEnvelopeJson NVARCHAR(MAX)   NULL,
        FailureReason   NVARCHAR(MAX)   NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_DeadLetter_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_DeadLetter_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_DeadLetter_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_DeadLetter PRIMARY KEY CLUSTERED (ERM_DeadLetterID)
    );
END
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'002_core_tables.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.0.0', ERM.fn_SystemUserID());
GO

GO

/* ==========================================================================
   SCRIPT: 003_seed_reference_data.sql
   ========================================================================== */
GO
PRINT '--- 003_seed_reference_data.sql ---';
GO

/* =============================================================================
   ERP Error Management Framework
   Script 003 - Seed reference data (MERGE-based, re-runnable, non-destructive)

   Every value here is a starting point that an administrator can change from
   the admin console.  Re-running this script restores the shipped defaults for
   rows that are missing but never deletes rows you added.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ------------------------------------------------------------- severity -- */
MERGE ERM.ERM_Severity AS t
USING (VALUES
    (1, N'critical', N'Critical', 1),
    (2, N'high',     N'High',     2),
    (3, N'medium',   N'Medium',   3),
    (4, N'low',      N'Low',      4),
    (5, N'info',     N'Information', 5)
) AS s (SeverityID, Code, DisplayName, RankOrder)
    ON t.SeverityID = s.SeverityID
WHEN NOT MATCHED THEN
    INSERT (SeverityID, Code, DisplayName, RankOrder, CreatedBy)
    VALUES (s.SeverityID, s.Code, s.DisplayName, s.RankOrder, ERM.fn_SystemUserID());
GO

/* ---------------------------------------------------------------- layer -- */
MERGE ERM.ERM_AppLayer AS t
USING (VALUES
    (1, N'angular',       N'Angular / front end'),
    (2, N'http',          N'HTTP / API transport'),
    (3, N'webapi',        N'ASP.NET Web API'),
    (4, N'business',      N'Business logic'),
    (5, N'data',          N'Data access'),
    (6, N'database',      N'SQL Server'),
    (7, N'integration',   N'External integration'),
    (8, N'infrastructure',N'Infrastructure / hosting')
) AS s (LayerID, Code, DisplayName)
    ON t.LayerID = s.LayerID
WHEN NOT MATCHED THEN
    INSERT (LayerID, Code, DisplayName, CreatedBy)
    VALUES (s.LayerID, s.Code, s.DisplayName, ERM.fn_SystemUserID());
GO

/* ------------------------------------------------------------- category -- */
/* These map 1:1 onto the error list in the brief.  DefaultSeverityID is what
   the classifier assigns when nothing more specific is known.                 */
MERGE ERM.ERM_ErrorCategory AS t
USING (VALUES
    (10, N'angular_runtime',   N'Angular runtime error',            2),
    (11, N'angular_render',    N'Template / rendering error',       2),
    (12, N'validation',        N'Form / validation error',          4),
    (13, N'submit_action',     N'Button / submit action error',     3),
    (14, N'lov_lookup',        N'LOV / lookup error',               3),
    (15, N'client_network',    N'Client network / offline',         3),
    (16, N'chunk_load',        N'Lazy chunk load failure',          2),
    (20, N'http_client',       N'HTTP 4xx (client)',                3),
    (21, N'http_server',       N'HTTP 5xx (server)',                2),
    (22, N'http_timeout',      N'HTTP timeout',                     2),
    (23, N'auth',              N'Authentication / authorisation',   3),
    (30, N'api_unhandled',     N'Unhandled .NET exception',         1),
    (31, N'business_rule',     N'Business rule violation',          4),
    (32, N'concurrency',       N'Concurrency / optimistic lock',    3),
    (33, N'serialization',     N'Serialisation / model binding',    3),
    (40, N'sql_error',         N'SQL Server error',                 1),
    (41, N'sql_procedure',     N'Stored procedure error',           1),
    (42, N'sql_constraint',    N'Constraint / referential integrity',3),
    (43, N'sql_deadlock',      N'Deadlock',                         2),
    (44, N'sql_timeout',       N'Query / command timeout',          2),
    (45, N'db_connection',     N'Database connection failure',      1),
    (50, N'integration',       N'External service failure',         2),
    (60, N'configuration',     N'Configuration error',              2),
    (99, N'unclassified',      N'Unclassified',                     3)
) AS s (CategoryID, Code, DisplayName, DefaultSeverityID)
    ON t.CategoryID = s.CategoryID
WHEN NOT MATCHED THEN
    INSERT (CategoryID, Code, DisplayName, DefaultSeverityID, CreatedBy)
    VALUES (s.CategoryID, s.Code, s.DisplayName, s.DefaultSeverityID, ERM.fn_SystemUserID());
GO

/* -------------------------------------------------------- ticket status -- */
MERGE ERM.ERM_TicketStatus AS t
USING (VALUES
    (1, N'new',         N'New',                     1, 1, 0, 0),
    (2, N'assigned',    N'Assigned',                2, 1, 0, 0),
    (3, N'in_progress', N'In Progress',             3, 1, 0, 0),
    (4, N'waiting_info',N'Waiting for Information', 4, 1, 0, 1),
    (5, N'resolved',    N'Resolved',                5, 1, 0, 0),
    (6, N'closed',      N'Closed',                  6, 0, 1, 0),
    (7, N'cancelled',   N'Cancelled',               7, 0, 1, 0),
    (8, N'reopened',    N'Reopened',                8, 1, 0, 0)
) AS s (StatusID, Code, DisplayName, RankOrder, IsOpen, IsTerminal, IsPaused)
    ON t.StatusID = s.StatusID
WHEN NOT MATCHED THEN
    INSERT (StatusID, Code, DisplayName, RankOrder, IsOpen, IsTerminal, IsPaused, CreatedBy)
    VALUES (s.StatusID, s.Code, s.DisplayName, s.RankOrder, s.IsOpen, s.IsTerminal, s.IsPaused, ERM.fn_SystemUserID());
GO

/* ---------------------------------------------------------- transitions -- */
/* New -> Assigned -> In Progress -> Waiting for Information -> Resolved -> Closed,
   plus the realistic side paths (cancel, reopen, resolve straight from In
   Progress, bounce back out of Waiting).                                      */
MERGE ERM.ERM_TicketStatusTransition AS t
USING (VALUES
    (1, 2, 0, 1),  (1, 3, 0, 1),  (1, 7, 1, 0),
    (2, 3, 0, 0),  (2, 4, 1, 0),  (2, 1, 1, 0),  (2, 7, 1, 0),
    (3, 4, 1, 0),  (3, 5, 1, 0),  (3, 2, 1, 0),  (3, 7, 1, 0),
    (4, 3, 0, 0),  (4, 5, 1, 0),  (4, 7, 1, 0),
    (5, 6, 0, 0),  (5, 8, 1, 0),
    (6, 8, 1, 0),
    (8, 2, 0, 1),  (8, 3, 0, 1),  (8, 5, 1, 0)
) AS s (FromStatusID, ToStatusID, RequiresComment, RequiresAssignee)
    ON t.FromStatusID = s.FromStatusID AND t.ToStatusID = s.ToStatusID
WHEN NOT MATCHED THEN
    INSERT (FromStatusID, ToStatusID, RequiresComment, RequiresAssignee, CreatedBy)
    VALUES (s.FromStatusID, s.ToStatusID, s.RequiresComment, s.RequiresAssignee, ERM.fn_SystemUserID());
GO

/* --------------------------------------------------------------- queues -- */
IF NOT EXISTS (SELECT 1 FROM ERM.ERM_TicketQueue WHERE Code = N'general')
    INSERT ERM.ERM_TicketQueue (Code, DisplayName, ErpModuleMatch, IsDefault, CreatedBy)
    VALUES (N'general', N'General Support', NULL, 1, ERM.fn_SystemUserID());
IF NOT EXISTS (SELECT 1 FROM ERM.ERM_TicketQueue WHERE Code = N'application')
    INSERT ERM.ERM_TicketQueue (Code, DisplayName, ErpModuleMatch, IsDefault, CreatedBy)
    VALUES (N'application', N'Application Support', NULL, 0, ERM.fn_SystemUserID());
IF NOT EXISTS (SELECT 1 FROM ERM.ERM_TicketQueue WHERE Code = N'database')
    INSERT ERM.ERM_TicketQueue (Code, DisplayName, ErpModuleMatch, IsDefault, CreatedBy)
    VALUES (N'database', N'Database Team', NULL, 0, ERM.fn_SystemUserID());
GO

/* ------------------------------------------------------------------ SLA -- */
MERGE ERM.ERM_SlaPolicy AS t
USING (VALUES
    (1, 15,  240),     -- critical: respond 15 min, resolve 4 h
    (2, 60,  480),     -- high
    (3, 240, 2880),    -- medium: 4 h / 2 days
    (4, 480, 10080),   -- low
    (5, 1440,43200)    -- info
) AS s (SeverityID, FirstResponseMinutes, ResolutionMinutes)
    ON t.SeverityID = s.SeverityID AND t.ERM_TicketQueueID IS NULL
WHEN NOT MATCHED THEN
    INSERT (SeverityID, ERM_TicketQueueID, FirstResponseMinutes, ResolutionMinutes, CreatedBy)
    VALUES (s.SeverityID, NULL, s.FirstResponseMinutes, s.ResolutionMinutes, ERM.fn_SystemUserID());
GO

/* ------------------------------------------------- redaction allow-list -- */
/* Only these keys survive capture with their real value; everything else in
   the same scope is stored as '***'.                                          */
MERGE ERM.ERM_RedactionAllowList AS t
USING (VALUES
    (N'header', N'content-type'),        (N'header', N'accept'),
    (N'header', N'accept-language'),     (N'header', N'user-agent'),
    (N'header', N'referer'),             (N'header', N'x-correlation-id'),
    (N'header', N'x-request-id'),        (N'header', N'x-erp-module'),
    (N'header', N'x-erp-screen'),        (N'header', N'x-app-version'),
    (N'query',  N'page'),                (N'query',  N'pageSize'),
    (N'query',  N'sort'),                (N'query',  N'sortDirection'),
    (N'query',  N'id'),                  (N'query',  N'code'),
    (N'query',  N'lovCode'),             (N'query',  N'moduleCode'),
    (N'query',  N'fromDate'),            (N'query',  N'toDate'),
    (N'body',   N'id'),                  (N'body',   N'code'),
    (N'body',   N'documentNo'),          (N'body',   N'status'),
    (N'body',   N'moduleCode'),          (N'body',   N'screenCode'),
    (N'body',   N'action'),              (N'body',   N'rowVersion'),
    (N'route',  N'id'),                  (N'route',  N'controller'),
    (N'route',  N'action')
) AS s (Scope, KeyName)
    ON t.Scope = s.Scope AND t.KeyName = s.KeyName
WHEN NOT MATCHED THEN
    INSERT (Scope, KeyName, CreatedBy) VALUES (s.Scope, s.KeyName, ERM.fn_SystemUserID());
GO

/* ------------------------------------------------------------- settings -- */
MERGE ERM.ERM_Setting AS t
USING (VALUES
    (N'capture.enabled',                  N'true',  N'bool', N'Master switch. false = the API accepts and discards envelopes.'),
    (N'capture.maxStackTraceChars',       N'20000', N'int',  N'Stack traces longer than this are truncated with a marker.'),
    (N'capture.maxBreadcrumbs',           N'25',    N'int',  N'Size of the client-side breadcrumb ring buffer.'),
    (N'capture.storeRequestBody',         N'true',  N'bool', N'Persist the (redacted) request body on the detail row.'),
    (N'capture.storeResponseBody',        N'false', N'bool', N'Off by default: responses are the likeliest place for bulk PII.'),
    (N'capture.sampling.infoPercent',     N'10',    N'int',  N'Percent of severity=info occurrences actually persisted.'),
    (N'dedup.windowMinutes',              N'60',    N'int',  N'Rolling window used by auto-ticket occurrence thresholds.'),
    (N'dedup.stackFrameDepth',            N'5',     N'int',  N'Frames included in the fingerprint signature.'),
    (N'ui.showErrorReference',            N'true',  N'bool', N'Show ERR-... in the modal even when no ticket is raised.'),
    (N'ui.allowUserDescription',          N'true',  N'bool', N'Let the user type what they were doing before submitting.'),
    (N'ui.suppressRepeatSeconds',         N'20',    N'int',  N'Do not re-open the modal for the same fingerprint within N seconds.'),
    (N'ticket.autoAssignToQueueOwner',    N'false', N'bool', N'Assign new tickets to the queue owner automatically.'),
    (N'ticket.reopenWindowDays',          N'14',    N'int',  N'A closed ticket can be reopened within this many days.'),
    (N'ticket.attachRecurrenceToOpen',    N'true',  N'bool', N'New occurrences of a fingerprint attach to its open ticket.'),
    (N'config.cacheSeconds',              N'300',   N'int',  N'How long the API caches these settings before re-reading.'),
    (N'notify.onStatusChange',            N'true',  N'bool', N'Emit a notification to the reporter on each visible change.')
) AS s (SettingKey, SettingValue, DataType, Description)
    ON t.SettingKey = s.SettingKey
WHEN NOT MATCHED THEN
    INSERT (SettingKey, SettingValue, DataType, Description, CreatedBy)
    VALUES (s.SettingKey, s.SettingValue, s.DataType, s.Description, ERM.fn_SystemUserID());
GO

/* -------------------------------------------------- auto-ticket rules ---- */
/* Shipped conservative on purpose: only a critical error that has already
   happened three times in an hour raises a ticket by itself.  Everything else
   waits for a human to press Report.                                          */
IF NOT EXISTS (SELECT 1 FROM ERM.ERM_AutoTicketRule WHERE RuleName = N'Critical recurring')
    INSERT ERM.ERM_AutoTicketRule (RuleName, MinSeverityID, MinOccurrences, WindowMinutes, TargetQueueID, CreatedBy)
    SELECT N'Critical recurring', 1, 3, 60, (SELECT ERM_TicketQueueID FROM ERM.ERM_TicketQueue WHERE Code = N'application'), ERM.fn_SystemUserID();
IF NOT EXISTS (SELECT 1 FROM ERM.ERM_AutoTicketRule WHERE RuleName = N'Database unavailable')
    INSERT ERM.ERM_AutoTicketRule (RuleName, CategoryID, MinOccurrences, WindowMinutes, TargetQueueID, CreatedBy)
    SELECT N'Database unavailable', 45, 1, 15, (SELECT ERM_TicketQueueID FROM ERM.ERM_TicketQueue WHERE Code = N'database'), ERM.fn_SystemUserID();
GO

/* ------------------------------------------------------------- retention -- */
MERGE ERM.ERM_RetentionPolicy AS t
USING (VALUES
    (N'occurrence_detail',  30,  0,    5000),  -- payloads archived after 30 days
    (N'occurrence',        180,  730,  5000),  -- events archived at 6 months, purged at 2 years
    (N'ticket',            365,  0,    2000),  -- closed tickets archived after a year, never purged
    (N'audit',             365,  0,    5000)
) AS s (DataSet, ArchiveAfterDays, PurgeAfterDays, BatchSize)
    ON t.DataSet = s.DataSet
WHEN NOT MATCHED THEN
    INSERT (DataSet, ArchiveAfterDays, PurgeAfterDays, BatchSize, CreatedBy)
    VALUES (s.DataSet, s.ArchiveAfterDays, s.PurgeAfterDays, s.BatchSize, ERM.fn_SystemUserID());
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'003_seed_reference_data.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.0.0', ERM.fn_SystemUserID());
GO

GO

/* ==========================================================================
   SCRIPT: 004_programmability.sql
   ========================================================================== */
GO
PRINT '--- 004_programmability.sql ---';
GO

/* =============================================================================
   ERP Error Management Framework
   Script 004 - Stored procedures and views (the framework's entire public API
                at the database level)

   The application layer never issues ad-hoc DML against these tables.  It calls
   these procedures.  That is what lets the schema evolve without redeploying
   the ERP, and what lets the application login hold EXECUTE-only rights.

   Every procedure is CREATE OR ALTER (SQL Server 2016 SP1+).
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =============================================================================
   Helper: read a typed setting
   ============================================================================= */
CREATE OR ALTER FUNCTION ERM.fn_SettingInt (@Key NVARCHAR(100), @Default INT)
RETURNS INT
AS
BEGIN
    DECLARE @v NVARCHAR(400) = (SELECT SettingValue FROM ERM.ERM_Setting WHERE SettingKey = @Key);
    RETURN CASE WHEN @v IS NULL OR TRY_CONVERT(INT, @v) IS NULL THEN @Default ELSE CONVERT(INT, @v) END;
END
GO

CREATE OR ALTER FUNCTION ERM.fn_SettingBit (@Key NVARCHAR(100), @Default BIT)
RETURNS BIT
AS
BEGIN
    DECLARE @v NVARCHAR(400) = (SELECT LOWER(SettingValue) FROM ERM.ERM_Setting WHERE SettingKey = @Key);
    RETURN CASE WHEN @v IN (N'true', N'1') THEN CONVERT(BIT,1)
                WHEN @v IN (N'false', N'0') THEN CONVERT(BIT,0)
                ELSE @Default END;
END
GO

/* =============================================================================
   usp_Error_Capture
   -----------------------------------------------------------------------------
   The single write path for every error from every layer.  Takes one JSON
   envelope so the transport contract can gain fields without an interface
   change, shreds it with OPENJSON, upserts the fingerprint, writes the
   occurrence + detail, evaluates the auto-ticket rules, and returns what the
   client needs in order to render the modal.

   Contract: this procedure NEVER raises to the caller for a data problem.  A
   malformed or unexpected envelope goes to ERM.ERM_DeadLetter and the procedure
   returns a NULL reference.  Capture must not be able to take down the ERP.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Error_Capture
(
    @EnvelopeJson   NVARCHAR(MAX),
    @Source         NVARCHAR(60) = NULL     -- 'angular' | 'webapi2' | 'aspnetcore'
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF ERM.fn_SettingBit(N'capture.enabled', 1) = 0
        BEGIN
            SELECT CONVERT(VARCHAR(30), NULL) AS ErrorReference,
                   CONVERT(BIGINT, NULL)      AS OccurrenceId,
                   CONVERT(BIGINT, NULL)      AS FingerprintId,
                   CONVERT(BIT, 0)            AS ShouldNotifyUser,
                   CONVERT(VARCHAR(30), NULL) AS AutoTicketNumber,
                   CONVERT(BIT, 0)            AS IsKnownIssue;
            RETURN;
        END

        DECLARE @e TABLE
        (
            FingerprintHash   CHAR(64),
            SignatureText     NVARCHAR(1000),
            LayerCode         NVARCHAR(30),
            CategoryCode      NVARCHAR(40),
            SeverityCode      NVARCHAR(20),
            ExceptionType     NVARCHAR(400),
            Message           NVARCHAR(2000),
            NormalizedMessage NVARCHAR(2000),
            OccurredUtc       DATETIME2(3),
            OccurredLocal     DATETIME2(3),
            ClientUtcOffsetMin SMALLINT,
            ErpModule         NVARCHAR(100),
            Screen            NVARCHAR(200),
            RouteUrl          NVARCHAR(500),
            Component         NVARCHAR(200),
            ActionName        NVARCHAR(200),
            FormName          NVARCHAR(200),
            LovName           NVARCHAR(200),
            ApiApplication    NVARCHAR(100),
            ApiController     NVARCHAR(200),
            ApiAction         NVARCHAR(200),
            ApiEndpoint       NVARCHAR(400),
            HttpMethod        VARCHAR(10),
            HttpStatusCode    SMALLINT,
            DurationMs        INT,
            SqlErrorNumber    INT,
            SqlErrorSeverity  TINYINT,
            SqlErrorState     TINYINT,
            SqlObjectName     NVARCHAR(256),
            SqlLineNumber     INT,
            SqlServerName     NVARCHAR(128),
            SqlDatabaseName   NVARCHAR(128),
            SqlSchemaName     NVARCHAR(128),
            UserProfileID     INT,
            UserName          NVARCHAR(200),
            UserDisplayName   NVARCHAR(200),
            TenantID          NVARCHAR(64),
            SessionID         NVARCHAR(100),
            ClientIp          NVARCHAR(64),
            CorrelationID     UNIQUEIDENTIFIER,
            RequestID         UNIQUEIDENTIFIER,
            ParentErrorReference VARCHAR(30),
            Environment       NVARCHAR(40),
            AppVersion        NVARCHAR(60),
            MachineName       NVARCHAR(128),
            BrowserName       NVARCHAR(60),
            BrowserVersion    NVARCHAR(40),
            OsName            NVARCHAR(60),
            DeviceType        NVARCHAR(30),
            ScreenResolution  VARCHAR(20),
            Locale            NVARCHAR(20),
            StackTrace        NVARCHAR(MAX),
            InnerExceptionChain NVARCHAR(MAX),
            RequestPayloadJson  NVARCHAR(MAX),
            ResponsePayloadJson NVARCHAR(MAX),
            ValidationErrorsJson NVARCHAR(MAX),
            BreadcrumbsJson     NVARCHAR(MAX),
            CustomDataJson      NVARCHAR(MAX),
            SqlStatementText    NVARCHAR(MAX)
        );

        INSERT @e
        SELECT * FROM OPENJSON(@EnvelopeJson)
        WITH (
            FingerprintHash   CHAR(64)        '$.fingerprintHash',
            SignatureText     NVARCHAR(1000)  '$.signatureText',
            LayerCode         NVARCHAR(30)    '$.layer',
            CategoryCode      NVARCHAR(40)    '$.category',
            SeverityCode      NVARCHAR(20)    '$.severity',
            ExceptionType     NVARCHAR(400)   '$.exceptionType',
            Message           NVARCHAR(2000)  '$.message',
            NormalizedMessage NVARCHAR(2000)  '$.normalizedMessage',
            OccurredUtc       DATETIME2(3)    '$.occurredUtc',
            OccurredLocal     DATETIME2(3)    '$.occurredLocal',
            ClientUtcOffsetMin SMALLINT       '$.clientUtcOffsetMinutes',
            ErpModule         NVARCHAR(100)   '$.erpModule',
            Screen            NVARCHAR(200)   '$.screen',
            RouteUrl          NVARCHAR(500)   '$.routeUrl',
            Component         NVARCHAR(200)   '$.component',
            ActionName        NVARCHAR(200)   '$.actionName',
            FormName          NVARCHAR(200)   '$.formName',
            LovName           NVARCHAR(200)   '$.lovName',
            ApiApplication    NVARCHAR(100)   '$.apiApplication',
            ApiController     NVARCHAR(200)   '$.apiController',
            ApiAction         NVARCHAR(200)   '$.apiAction',
            ApiEndpoint       NVARCHAR(400)   '$.apiEndpoint',
            HttpMethod        VARCHAR(10)     '$.httpMethod',
            HttpStatusCode    SMALLINT        '$.httpStatusCode',
            DurationMs        INT             '$.durationMs',
            SqlErrorNumber    INT             '$.sql.number',
            SqlErrorSeverity  TINYINT         '$.sql.severity',
            SqlErrorState     TINYINT         '$.sql.state',
            SqlObjectName     NVARCHAR(256)   '$.sql.objectName',
            SqlLineNumber     INT             '$.sql.lineNumber',
            SqlServerName     NVARCHAR(128)   '$.sql.serverName',
            SqlDatabaseName   NVARCHAR(128)   '$.sql.databaseName',
            SqlSchemaName     NVARCHAR(128)   '$.sql.schemaName',
            UserProfileID     INT             '$.user.profileId',
            UserName          NVARCHAR(200)   '$.user.name',
            UserDisplayName   NVARCHAR(200)   '$.user.displayName',
            TenantID          NVARCHAR(64)    '$.user.tenantId',
            SessionID         NVARCHAR(100)   '$.user.sessionId',
            ClientIp          NVARCHAR(64)    '$.user.clientIp',
            CorrelationID     UNIQUEIDENTIFIER '$.correlationId',
            RequestID         UNIQUEIDENTIFIER '$.requestId',
            ParentErrorReference VARCHAR(30)  '$.parentErrorReference',
            Environment       NVARCHAR(40)    '$.environment',
            AppVersion        NVARCHAR(60)    '$.appVersion',
            MachineName       NVARCHAR(128)   '$.machineName',
            BrowserName       NVARCHAR(60)    '$.client.browserName',
            BrowserVersion    NVARCHAR(40)    '$.client.browserVersion',
            OsName            NVARCHAR(60)    '$.client.osName',
            DeviceType        NVARCHAR(30)    '$.client.deviceType',
            ScreenResolution  VARCHAR(20)     '$.client.screenResolution',
            Locale            NVARCHAR(20)    '$.client.locale',
            StackTrace        NVARCHAR(MAX)   '$.stackTrace',
            InnerExceptionChain NVARCHAR(MAX) '$.innerExceptionChain',
            RequestPayloadJson  NVARCHAR(MAX) '$.requestPayload'   AS JSON,
            ResponsePayloadJson NVARCHAR(MAX) '$.responsePayload'  AS JSON,
            ValidationErrorsJson NVARCHAR(MAX)'$.validationErrors' AS JSON,
            BreadcrumbsJson     NVARCHAR(MAX) '$.breadcrumbs'      AS JSON,
            CustomDataJson      NVARCHAR(MAX) '$.customData'       AS JSON,
            SqlStatementText    NVARCHAR(MAX) '$.sql.statement'
        );

        /* ---- resolve lookups, applying defaults where the caller was vague -- */
        DECLARE @LayerID TINYINT, @CategoryID SMALLINT, @SeverityID TINYINT;

        SELECT @LayerID = ISNULL((SELECT LayerID FROM ERM.ERM_AppLayer l
                                  WHERE l.Code = (SELECT LayerCode FROM @e)), 8);

        SELECT @CategoryID = ISNULL((SELECT CategoryID FROM ERM.ERM_ErrorCategory c
                                     WHERE c.Code = (SELECT CategoryCode FROM @e) AND c.IsActive = 1), 99);

        SELECT @SeverityID = COALESCE(
                    (SELECT SeverityID FROM ERM.ERM_Severity s
                     WHERE s.Code = (SELECT SeverityCode FROM @e) AND s.IsActive = 1),
                    (SELECT DefaultSeverityID FROM ERM.ERM_ErrorCategory WHERE CategoryID = @CategoryID),
                    3);

        DECLARE @Hash CHAR(64) = (SELECT FingerprintHash FROM @e);
        IF @Hash IS NULL OR LEN(@Hash) <> 64
        BEGIN
            /* No usable fingerprint: refuse to guess, dead-letter and get out.
               A wrong fingerprint is worse than none - it silently merges two
               unrelated problems into one ticket. */
            INSERT ERM.ERM_DeadLetter (Source, RawEnvelopeJson, FailureReason, CreatedBy)
            VALUES (@Source, @EnvelopeJson, N'Missing or malformed fingerprintHash', ERM.fn_SystemUserID());

            SELECT CONVERT(VARCHAR(30), NULL) AS ErrorReference, CONVERT(BIGINT, NULL) AS OccurrenceId,
                   CONVERT(BIGINT, NULL) AS FingerprintId, CONVERT(BIT, 1) AS ShouldNotifyUser,
                   CONVERT(VARCHAR(30), NULL) AS AutoTicketNumber, CONVERT(BIT, 0) AS IsKnownIssue;
            RETURN;
        END

        DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
        DECLARE @OccurredUtc DATETIME2(3) = ISNULL((SELECT OccurredUtc FROM @e), @Now);

        /* A client clock can be wildly wrong.  Clamp rather than trust: a 2031
           timestamp would sit at the top of every "recent errors" list forever. */
        IF @OccurredUtc > DATEADD(MINUTE, 5, @Now) OR @OccurredUtc < DATEADD(YEAR, -1, @Now)
            SET @OccurredUtc = @Now;

        DECLARE @ERM_ErrorFingerprintID BIGINT, @ERM_ErrorOccurrenceID BIGINT, @ErrorReference VARCHAR(30);
        DECLARE @IsKnownIssue BIT = 0, @IsMuted BIT = 0, @OpenTicketID BIGINT = NULL;

        BEGIN TRANSACTION;

            /* ---- upsert the fingerprint -------------------------------- */
            MERGE ERM.ERM_ErrorFingerprint WITH (HOLDLOCK) AS t
            USING (SELECT @Hash AS FingerprintHash) AS s
                ON t.FingerprintHash = s.FingerprintHash
            WHEN MATCHED THEN
                UPDATE SET LastSeenUtc     = CASE WHEN @OccurredUtc > t.LastSeenUtc THEN @OccurredUtc ELSE t.LastSeenUtc END,
                           OccurrenceCount = t.OccurrenceCount + 1,
                           -- Escalate, never de-escalate: if the same problem was
                           -- ever seen as critical, it stays critical.
                           SeverityID      = CASE WHEN @SeverityID < t.SeverityID THEN @SeverityID ELSE t.SeverityID END
            WHEN NOT MATCHED THEN
                INSERT (FingerprintHash, SignatureText, LayerID, CategoryID, SeverityID,
                        ExceptionType, NormalizedMessage, ErpModule, Screen, Component,
                        ApiEndpoint, SqlObjectName, FirstSeenUtc, LastSeenUtc, OccurrenceCount,
                        CreatedBy)
                VALUES (@Hash,
                        ISNULL((SELECT SignatureText FROM @e), N'(no signature supplied)'),
                        @LayerID, @CategoryID, @SeverityID,
                        (SELECT ExceptionType FROM @e),
                        (SELECT COALESCE(NormalizedMessage, Message) FROM @e),
                        (SELECT ErpModule FROM @e), (SELECT Screen FROM @e), (SELECT Component FROM @e),
                        (SELECT ApiEndpoint FROM @e), (SELECT SqlObjectName FROM @e),
                        @OccurredUtc, @OccurredUtc, 1,
                        /* A fingerprint is a PROBLEM, not a person's record. It
                           is created by the framework the first time a fault is
                           seen, so it is never attributable to the user who
                           happened to hit it first. */
                        ERM.fn_SystemUserID());

            SELECT @ERM_ErrorFingerprintID = ERM_ErrorFingerprintID,
                   @IsKnownIssue  = CASE WHEN TriageState IN (N'known_issue', N'muted') THEN 1 ELSE 0 END,
                   @IsMuted       = CASE WHEN TriageState = N'muted'
                                           OR (MutedUntilUtc IS NOT NULL AND MutedUntilUtc > @Now)
                                         THEN 1 ELSE 0 END,
                   @OpenTicketID  = OpenTicketID
            FROM ERM.ERM_ErrorFingerprint
            WHERE FingerprintHash = @Hash;

            /* ---- sampling: high-volume info noise does not need every row -- */
            DECLARE @InfoPct INT = ERM.fn_SettingInt(N'capture.sampling.infoPercent', 10);
            IF @SeverityID = 5 AND @InfoPct < 100
               AND (CONVERT(BIGINT, CONVERT(VARBINARY(4), SUBSTRING(@Hash, 1, 8), 2)) % 100) >= @InfoPct
            BEGIN
                /* Counted on the fingerprint above, body not persisted. */
                COMMIT TRANSACTION;
                SELECT CONVERT(VARCHAR(30), NULL) AS ErrorReference, CONVERT(BIGINT, NULL) AS OccurrenceId,
                       @ERM_ErrorFingerprintID AS FingerprintId, CONVERT(BIT, 0) AS ShouldNotifyUser,
                       CONVERT(VARCHAR(30), NULL) AS AutoTicketNumber, @IsKnownIssue AS IsKnownIssue;
                RETURN;
            END

            /* ---- reference number and occurrence row -------------------- */
            EXEC ERM.usp_NextReference @RefType = 'ERR', @Reference = @ErrorReference OUTPUT;

            DECLARE @ParentOccurrenceID BIGINT =
                (SELECT o.ERM_ErrorOccurrenceID FROM ERM.ERM_ErrorOccurrence o
                 WHERE o.ErrorReference = (SELECT ParentErrorReference FROM @e));

            INSERT ERM.ERM_ErrorOccurrence
            (
                ErrorReference, ERM_ErrorFingerprintID, OccurredUtc, OccurredLocal, ClientUtcOffsetMin,
                LayerID, CategoryID, SeverityID, ExceptionType, Message,
                ErpModule, Screen, RouteUrl, Component, ActionName, FormName, LovName,
                ApiApplication, ApiController, ApiAction, ApiEndpoint, HttpMethod, HttpStatusCode, DurationMs,
                SqlErrorNumber, SqlErrorSeverity, SqlErrorState, SqlObjectName, SqlLineNumber,
                SqlServerName, SqlDatabaseName, SqlSchemaName,
                UserProfileID, UserName, UserDisplayName, TenantID, SessionID, ClientIp,
                CorrelationID, RequestID, ParentOccurrenceID,
                Environment, AppVersion, MachineName,
                BrowserName, BrowserVersion, OsName, DeviceType, ScreenResolution, Locale,
                CreatedBy
            )
            SELECT
                @ErrorReference, @ERM_ErrorFingerprintID, @OccurredUtc, e.OccurredLocal, e.ClientUtcOffsetMin,
                @LayerID, @CategoryID, @SeverityID, e.ExceptionType, e.Message,
                e.ErpModule, e.Screen, e.RouteUrl, e.Component, e.ActionName, e.FormName, e.LovName,
                e.ApiApplication, e.ApiController, e.ApiAction, e.ApiEndpoint, e.HttpMethod, e.HttpStatusCode, e.DurationMs,
                e.SqlErrorNumber, e.SqlErrorSeverity, e.SqlErrorState, e.SqlObjectName, e.SqlLineNumber,
                e.SqlServerName, e.SqlDatabaseName, e.SqlSchemaName,
                ISNULL(e.UserProfileID, ERM.fn_SystemUserID()),
                e.UserName, e.UserDisplayName, e.TenantID, e.SessionID, e.ClientIp,
                ISNULL(e.CorrelationID, NEWID()), e.RequestID, @ParentOccurrenceID,
                ISNULL(e.Environment, N'unknown'), e.AppVersion, e.MachineName,
                e.BrowserName, e.BrowserVersion, e.OsName, e.DeviceType, e.ScreenResolution, e.Locale,
                /* CreatedBy IS the user who hit the error, which is exactly what
                   the standard means by it. -1 on a public page. */
                ISNULL(e.UserProfileID, ERM.fn_SystemUserID())
            FROM @e e;

            SET @ERM_ErrorOccurrenceID = SCOPE_IDENTITY();

            DECLARE @MaxStack INT = ERM.fn_SettingInt(N'capture.maxStackTraceChars', 20000);
            DECLARE @StoreReq BIT = ERM.fn_SettingBit(N'capture.storeRequestBody', 1);
            DECLARE @StoreRes BIT = ERM.fn_SettingBit(N'capture.storeResponseBody', 0);

            INSERT ERM.ERM_ErrorOccurrenceDetail
            (
                ERM_ErrorOccurrenceID, StackTrace, InnerExceptionChain, RequestPayloadJson,
                ResponsePayloadJson, ValidationErrorsJson, BreadcrumbsJson, CustomDataJson, SqlStatementText,
                CreatedBy
            )
            SELECT
                @ERM_ErrorOccurrenceID,
                CASE WHEN LEN(e.StackTrace) > @MaxStack
                     THEN LEFT(e.StackTrace, @MaxStack) + NCHAR(10) + N'... [truncated at ' + CONVERT(NVARCHAR(20), @MaxStack) + N' chars]'
                     ELSE e.StackTrace END,
                e.InnerExceptionChain,
                CASE WHEN @StoreReq = 1 THEN e.RequestPayloadJson END,
                CASE WHEN @StoreRes = 1 THEN e.ResponsePayloadJson END,
                e.ValidationErrorsJson, e.BreadcrumbsJson, e.CustomDataJson, e.SqlStatementText,
                ISNULL(e.UserProfileID, ERM.fn_SystemUserID())
            FROM @e e;

            /* Distinct-user count, maintained incrementally so the admin list
               does not have to COUNT(DISTINCT) over a 50-million-row table. */
            /* Counted on UserProfileID, not UserName: two people can share a
               display name, one person can have theirs corrected, and either
               would quietly corrupt "how many users does this affect" - which
               is the number that decides whether a problem gets fixed.
               -1 is excluded: every anonymous visitor would otherwise look
               like the same one user. */
            IF EXISTS (SELECT 1 FROM @e WHERE UserProfileID > 0)
               AND NOT EXISTS (
                    SELECT 1 FROM ERM.ERM_ErrorOccurrence o
                    WHERE o.ERM_ErrorFingerprintID = @ERM_ErrorFingerprintID
                      AND o.UserProfileID = (SELECT UserProfileID FROM @e)
                      AND o.ERM_ErrorOccurrenceID <> @ERM_ErrorOccurrenceID)
                UPDATE ERM.ERM_ErrorFingerprint
                   SET DistinctUserCount = DistinctUserCount + 1
                 WHERE ERM_ErrorFingerprintID = @ERM_ErrorFingerprintID;

            /* ---- attach to an already-open ticket for the same problem --- */
            DECLARE @AutoTicketNumber VARCHAR(30) = NULL;

            IF @OpenTicketID IS NOT NULL AND ERM.fn_SettingBit(N'ticket.attachRecurrenceToOpen', 1) = 1
            BEGIN
                INSERT ERM.ERM_TicketOccurrenceLink (ERM_TicketID, ERM_ErrorOccurrenceID, LinkReason, CreatedBy)
                VALUES (@OpenTicketID, @ERM_ErrorOccurrenceID, N'deduplicated', ERM.fn_SystemUserID());

                UPDATE ERM.ERM_Ticket
                   SET LinkedOccurrenceCount = LinkedOccurrenceCount + 1
                 WHERE ERM_TicketID = @OpenTicketID;

                UPDATE ERM.ERM_ErrorOccurrence SET ERM_TicketID = @OpenTicketID WHERE ERM_ErrorOccurrenceID = @ERM_ErrorOccurrenceID;
                SET @AutoTicketNumber = (SELECT TicketNumber FROM ERM.ERM_Ticket WHERE ERM_TicketID = @OpenTicketID);
            END

        COMMIT TRANSACTION;

        /* ---- auto-ticket rules (outside the capture transaction on purpose:
                a rule-evaluation problem must not roll back the captured error) */
        IF @AutoTicketNumber IS NULL AND @IsMuted = 0
        BEGIN
            DECLARE @WindowMin INT, @RuleQueueId SMALLINT, @RuleName NVARCHAR(100);

            SELECT TOP 1 @WindowMin = r.WindowMinutes, @RuleQueueId = r.TargetQueueID, @RuleName = r.RuleName
            FROM ERM.ERM_AutoTicketRule r
            CROSS APPLY (SELECT RankOrder FROM ERM.ERM_Severity WHERE SeverityID = @SeverityID) sv
            OUTER APPLY (SELECT RankOrder AS MinRank FROM ERM.ERM_Severity WHERE SeverityID = r.MinSeverityID) mr
            WHERE r.IsActive = 1
              AND (r.MinSeverityID  IS NULL OR sv.RankOrder <= mr.MinRank)
              AND (r.CategoryID     IS NULL OR r.CategoryID = @CategoryID)
              AND (r.LayerID        IS NULL OR r.LayerID    = @LayerID)
              AND (r.ErpModuleMatch IS NULL OR r.ErpModuleMatch = (SELECT ErpModule FROM @e))
              AND (r.EnvironmentMatch IS NULL OR r.EnvironmentMatch = (SELECT Environment FROM @e))
              AND r.MinOccurrences <= (
                    SELECT COUNT_BIG(*) FROM ERM.ERM_ErrorOccurrence o
                    WHERE o.ERM_ErrorFingerprintID = @ERM_ErrorFingerprintID
                      AND o.OccurredUtc >= DATEADD(MINUTE, -r.WindowMinutes, @Now))
            ORDER BY r.MinOccurrences DESC, r.ERM_AutoTicketRuleID;

            IF @RuleName IS NOT NULL
            BEGIN
                EXEC ERM.usp_Ticket_Create
                     @ERM_ErrorOccurrenceID      = @ERM_ErrorOccurrenceID,
                     @CreatedVia        = N'auto_rule',
                     @UserDescription   = NULL,
                     /* Raised by a rule, not a person. */
                     @ReportedByUserProfileID = NULL,
                     @ReportedByUserName= NULL,
                     @ERM_TicketQueueID           = @RuleQueueId,
                     @TicketNumber      = @AutoTicketNumber OUTPUT;
            END
        END

        /* ---- what the caller should do next ------------------------------ */
        SELECT @ErrorReference AS ErrorReference,
               @ERM_ErrorOccurrenceID   AS OccurrenceId,
               @ERM_ErrorFingerprintID  AS FingerprintId,
               CASE WHEN @IsMuted = 1 THEN CONVERT(BIT,0) ELSE CONVERT(BIT,1) END AS ShouldNotifyUser,
               @AutoTicketNumber AS AutoTicketNumber,
               @IsKnownIssue   AS IsKnownIssue;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        BEGIN TRY
            INSERT ERM.ERM_DeadLetter (Source, RawEnvelopeJson, FailureReason, CreatedBy)
            VALUES (@Source, @EnvelopeJson,
                    CONCAT(N'Msg ', ERROR_NUMBER(), N', Line ', ERROR_LINE(), N': ', ERROR_MESSAGE()));
        END TRY
        BEGIN CATCH
            /* Even the dead-letter write failed (disk full, schema gone).
               Swallow: the ERP transaction must survive regardless. */
        END CATCH

        SELECT CONVERT(VARCHAR(30), NULL) AS ErrorReference, CONVERT(BIGINT, NULL) AS OccurrenceId,
               CONVERT(BIGINT, NULL) AS FingerprintId, CONVERT(BIT, 1) AS ShouldNotifyUser,
               CONVERT(VARCHAR(30), NULL) AS AutoTicketNumber, CONVERT(BIT, 0) AS IsKnownIssue;
    END CATCH
END
GO

/* =============================================================================
   usp_Ticket_Create
   -----------------------------------------------------------------------------
   Called when the user presses "Report issue" in the modal, or by an
   auto-ticket rule.  If the same problem already has an open ticket, this does
   NOT create a second one - it links the occurrence and returns the existing
   number.  That is the whole point of the fingerprint.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_Create
(
    @ERM_ErrorOccurrenceID       BIGINT,
    @CreatedVia         NVARCHAR(20)   = N'user',
    @UserDescription    NVARCHAR(MAX)  = NULL,
    @ReportedByUserProfileID INT       = NULL,
    @ReportedByUserName NVARCHAR(200)  = NULL,
    @ERM_TicketQueueID            SMALLINT       = NULL,
    @TicketNumber       VARCHAR(30)    OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ERM_ErrorFingerprintID BIGINT, @SeverityID TINYINT, @ErpModule NVARCHAR(100),
            @Environment NVARCHAR(40), @Message NVARCHAR(2000), @Screen NVARCHAR(200),
            @ExistingTicketId BIGINT, @Now DATETIME2(3) = SYSUTCDATETIME();

    SELECT @ERM_ErrorFingerprintID = o.ERM_ErrorFingerprintID, @SeverityID = o.SeverityID,
           @ErpModule = o.ErpModule, @Environment = o.Environment,
           @Message = o.Message, @Screen = o.Screen
    FROM ERM.ERM_ErrorOccurrence o
    WHERE o.ERM_ErrorOccurrenceID = @ERM_ErrorOccurrenceID;

    IF @ERM_ErrorFingerprintID IS NULL
    BEGIN
        SET @TicketNumber = NULL;
        RETURN;
    END

    /* ---- already-open ticket for this problem? ------------------------- */
    SELECT @ExistingTicketId = f.OpenTicketID
    FROM ERM.ERM_ErrorFingerprint f
    WHERE f.ERM_ErrorFingerprintID = @ERM_ErrorFingerprintID
      AND f.OpenTicketID IS NOT NULL
      AND EXISTS (SELECT 1 FROM ERM.ERM_Ticket tk
                  JOIN ERM.ERM_TicketStatus st ON st.StatusID = tk.StatusID
                  WHERE tk.ERM_TicketID = f.OpenTicketID AND st.IsTerminal = 0);

    IF @ExistingTicketId IS NOT NULL
    BEGIN
        BEGIN TRANSACTION;
            IF NOT EXISTS (SELECT 1 FROM ERM.ERM_TicketOccurrenceLink
                           WHERE ERM_TicketID = @ExistingTicketId AND ERM_ErrorOccurrenceID = @ERM_ErrorOccurrenceID)
            BEGIN
                INSERT ERM.ERM_TicketOccurrenceLink (ERM_TicketID, ERM_ErrorOccurrenceID, LinkReason, CreatedBy)
                VALUES (@ExistingTicketId, @ERM_ErrorOccurrenceID, N'deduplicated',
                        ISNULL(@ReportedByUserProfileID, ERM.fn_SystemUserID()));

                UPDATE ERM.ERM_Ticket
                   SET LinkedOccurrenceCount = LinkedOccurrenceCount + 1
                 WHERE ERM_TicketID = @ExistingTicketId;
            END

            UPDATE ERM.ERM_ErrorOccurrence SET ERM_TicketID = @ExistingTicketId WHERE ERM_ErrorOccurrenceID = @ERM_ErrorOccurrenceID;

            /* The user's own words are still worth keeping - as a comment on
               the existing ticket, not as a duplicate ticket. */
            IF @UserDescription IS NOT NULL AND LEN(LTRIM(RTRIM(@UserDescription))) > 0
                INSERT ERM.ERM_TicketComment (ERM_TicketID, AuthorUserProfileID, AuthorUserName, AuthorRole, CommentText, IsCustomerVisible, CreatedBy)
                VALUES (@ExistingTicketId, ISNULL(@ReportedByUserProfileID, ERM.fn_SystemUserID()),
                        @ReportedByUserName, N'reporter',
                        CONCAT(N'Additional report (', @ERM_ErrorOccurrenceID, N'): ', @UserDescription), 1,
                        ISNULL(@ReportedByUserProfileID, ERM.fn_SystemUserID()));
        COMMIT TRANSACTION;

        SET @TicketNumber = (SELECT TicketNumber FROM ERM.ERM_Ticket WHERE ERM_TicketID = @ExistingTicketId);
        SELECT @TicketNumber AS TicketNumber, @ExistingTicketId AS TicketId, CONVERT(BIT,1) AS WasDeduplicated;
        RETURN;
    END

    /* ---- routing ------------------------------------------------------- */
    IF @ERM_TicketQueueID IS NULL
        SELECT TOP 1 @ERM_TicketQueueID = ERM_TicketQueueID FROM ERM.ERM_TicketQueue
        WHERE IsActive = 1 AND ErpModuleMatch = @ErpModule ORDER BY ERM_TicketQueueID;
    IF @ERM_TicketQueueID IS NULL
        SELECT TOP 1 @ERM_TicketQueueID = ERM_TicketQueueID FROM ERM.ERM_TicketQueue
        WHERE IsActive = 1 AND IsDefault = 1 ORDER BY ERM_TicketQueueID;
    IF @ERM_TicketQueueID IS NULL
        SELECT TOP 1 @ERM_TicketQueueID = ERM_TicketQueueID FROM ERM.ERM_TicketQueue WHERE IsActive = 1 ORDER BY ERM_TicketQueueID;

    DECLARE @ERM_SlaPolicyID SMALLINT =
        COALESCE((SELECT TOP 1 ERM_SlaPolicyID FROM ERM.ERM_SlaPolicy
                  WHERE IsActive = 1 AND SeverityID = @SeverityID AND ERM_TicketQueueID = @ERM_TicketQueueID),
                 (SELECT TOP 1 ERM_SlaPolicyID FROM ERM.ERM_SlaPolicy
                  WHERE IsActive = 1 AND SeverityID = @SeverityID AND ERM_TicketQueueID IS NULL));

    DECLARE @NewTicketId BIGINT;
    EXEC ERM.usp_NextReference @RefType = 'TKT', @Reference = @TicketNumber OUTPUT;

    DECLARE @Title NVARCHAR(400) =
        LEFT(CONCAT(ISNULL(@ErpModule, N'ERP'), N' / ', ISNULL(@Screen, N'(unknown screen)'), N' - ',
                    ISNULL(@Message, N'Unexpected error')), 400);

    BEGIN TRANSACTION;
        INSERT ERM.ERM_Ticket
        (
            TicketNumber, ERM_ErrorOccurrenceID, ERM_ErrorFingerprintID, StatusID, SeverityID, ERM_TicketQueueID, ERM_SlaPolicyID,
            Title, UserDescription, ReportedByUserProfileID, ReportedByUserName, CreatedVia,
            ErpModule, Environment, CreatedUtc, LastStatusChangeUtc, LinkedOccurrenceCount,
            CreatedBy
        )
        VALUES
        (
            @TicketNumber, @ERM_ErrorOccurrenceID, @ERM_ErrorFingerprintID, 1 /*new*/, @SeverityID, @ERM_TicketQueueID, @ERM_SlaPolicyID,
            @Title, @UserDescription,
            /* An auto-rule ticket has no reporter; -1 says so rather than
               attributing it to whoever happened to trigger the threshold. */
            ISNULL(@ReportedByUserProfileID, ERM.fn_SystemUserID()), @ReportedByUserName, @CreatedVia,
            @ErpModule, @Environment, @Now, @Now, 1,
            ISNULL(@ReportedByUserProfileID, ERM.fn_SystemUserID())
        );

        SET @NewTicketId = SCOPE_IDENTITY();

        INSERT ERM.ERM_TicketStatusHistory
            (ERM_TicketID, SequenceNo, FromStatusID, ToStatusID, ChangedByUserProfileID, ChangedByUserName,
             ChangedUtc, MinutesInFromStatus, Comments, IsCustomerVisible, CreatedBy)
        VALUES
            (@NewTicketId, 1, NULL, 1, ISNULL(@ReportedByUserProfileID, ERM.fn_SystemUserID()),
             @ReportedByUserName, @Now, NULL,
             CASE WHEN @CreatedVia = N'auto_rule'
                  THEN N'Ticket raised automatically by an error-management rule.'
                  ELSE N'Ticket raised by the user from the error dialog.' END, 1,
             ISNULL(@ReportedByUserProfileID, ERM.fn_SystemUserID()));

        INSERT ERM.ERM_TicketOccurrenceLink (ERM_TicketID, ERM_ErrorOccurrenceID, LinkReason, CreatedBy)
        VALUES (@NewTicketId, @ERM_ErrorOccurrenceID, N'primary',
                ISNULL(@ReportedByUserProfileID, ERM.fn_SystemUserID()));

        UPDATE ERM.ERM_ErrorOccurrence SET ERM_TicketID = @NewTicketId WHERE ERM_ErrorOccurrenceID = @ERM_ErrorOccurrenceID;

        UPDATE ERM.ERM_ErrorFingerprint
           SET OpenTicketID = @NewTicketId,
               TriageState  = CASE WHEN TriageState = N'new' THEN N'acknowledged' ELSE TriageState END
         WHERE ERM_ErrorFingerprintID = @ERM_ErrorFingerprintID;
    COMMIT TRANSACTION;

    /* Guarded rather than assumed: 012 is part of the standard install, but a
       missing notification script must not break ticket creation. Deferred name
       resolution would let the EXEC compile and then fail at run time, which is
       the worst of both. */
    IF OBJECT_ID(N'ERM.usp_Notification_Enqueue', N'P') IS NOT NULL
        EXEC ERM.usp_Notification_Enqueue
             @RecipientUserProfileID = @ReportedByUserProfileID,
             @EventKind    = N'created',
             @ERM_TicketID = @NewTicketId,
             @TicketNumber = @TicketNumber,
             @Title        = N'Your issue has been logged',
             @Body         = @Title,
             /* NULL, not the reporter: this one IS about their own action, and
                a confirmation that the issue was received is the single most
                useful thing to tell them. */
             @ActedByUserProfileID = NULL;

    SELECT @TicketNumber AS TicketNumber, @NewTicketId AS TicketId, CONVERT(BIT,0) AS WasDeduplicated;
END
GO

/* =============================================================================
   usp_Ticket_ChangeStatus
   -----------------------------------------------------------------------------
   The only way a ticket's status moves.  Validates the transition against the
   configured workflow, writes the audit row, and maintains every metric the
   brief listed - including "time spent in each status", which is recorded on
   the history row as it happens rather than re-derived at report time.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_ChangeStatus
(
    @ERM_TicketID           BIGINT,
    @ToStatusID         TINYINT,
    @ChangedByUserProfileID INT       = NULL,
    @ChangedByUserName  NVARCHAR(200) = NULL,
    @Comments           NVARCHAR(MAX) = NULL,
    @AssignToUserProfileID INT        = NULL,
    @AssignToUserName   NVARCHAR(200) = NULL,
    @IsCustomerVisible  BIT = 1,
    @ResolutionCode     NVARCHAR(60)  = NULL,
    @ResolutionNotes    NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @FromStatusID TINYINT, @LastChangeUtc DATETIME2(3), @CreatedUtc DATETIME2(3),
            @ERM_ErrorFingerprintID BIGINT, @SeqNo INT, @FromIsPaused BIT, @ToIsTerminal BIT,
            @ToIsOpen BIT, @FirstResponseUtc DATETIME2(3);

    SELECT @FromStatusID   = t.StatusID,
           @LastChangeUtc  = t.LastStatusChangeUtc,
           @CreatedUtc     = t.CreatedUtc,
           @ERM_ErrorFingerprintID  = t.ERM_ErrorFingerprintID,
           @FirstResponseUtc = t.FirstResponseUtc
    FROM ERM.ERM_Ticket t WHERE t.ERM_TicketID = @ERM_TicketID;

    IF @FromStatusID IS NULL
    BEGIN
        RAISERROR (N'Ticket %I64d does not exist.', 16, 1, @ERM_TicketID);
        RETURN;
    END

    IF @FromStatusID = @ToStatusID
    BEGIN
        RAISERROR (N'Ticket is already in that status.', 16, 1);
        RETURN;
    END

    /* ---- is this move legal in the configured workflow? ---------------- */
    DECLARE @RequiresComment BIT, @RequiresAssignee BIT;
    SELECT @RequiresComment = RequiresComment, @RequiresAssignee = RequiresAssignee
    FROM ERM.ERM_TicketStatusTransition
    WHERE FromStatusID = @FromStatusID AND ToStatusID = @ToStatusID AND IsActive = 1;

    IF @RequiresComment IS NULL
    BEGIN
        DECLARE @fromName NVARCHAR(80) = (SELECT DisplayName FROM ERM.ERM_TicketStatus WHERE StatusID = @FromStatusID);
        DECLARE @toName   NVARCHAR(80) = (SELECT DisplayName FROM ERM.ERM_TicketStatus WHERE StatusID = @ToStatusID);
        RAISERROR (N'Transition "%s" -> "%s" is not permitted by the configured workflow.', 16, 1, @fromName, @toName);
        RETURN;
    END

    IF @RequiresComment = 1 AND (@Comments IS NULL OR LEN(LTRIM(RTRIM(@Comments))) = 0)
    BEGIN
        RAISERROR (N'This status change requires a comment.', 16, 1);
        RETURN;
    END

    DECLARE @EffectiveAssigneeId INT =
        COALESCE(@AssignToUserProfileID, (SELECT AssignedToUserProfileID FROM ERM.ERM_Ticket WHERE ERM_TicketID = @ERM_TicketID));

    IF @RequiresAssignee = 1 AND @EffectiveAssigneeId IS NULL
    BEGIN
        RAISERROR (N'This status change requires the ticket to be assigned.', 16, 1);
        RETURN;
    END

    SELECT @FromIsPaused = IsPaused FROM ERM.ERM_TicketStatus WHERE StatusID = @FromStatusID;
    SELECT @ToIsTerminal = IsTerminal, @ToIsOpen = IsOpen FROM ERM.ERM_TicketStatus WHERE StatusID = @ToStatusID;

    DECLARE @MinutesInFrom INT = DATEDIFF(MINUTE, @LastChangeUtc, @Now);

    BEGIN TRANSACTION;

        SELECT @SeqNo = ISNULL(MAX(SequenceNo), 0) + 1
        FROM ERM.ERM_TicketStatusHistory WITH (UPDLOCK, HOLDLOCK)
        WHERE ERM_TicketID = @ERM_TicketID;

        INSERT ERM.ERM_TicketStatusHistory
            (ERM_TicketID, SequenceNo, FromStatusID, ToStatusID, ChangedByUserProfileID, ChangedByUserName,
             ChangedUtc, MinutesInFromStatus, Comments, IsCustomerVisible, CreatedBy)
        VALUES
            (@ERM_TicketID, @SeqNo, @FromStatusID, @ToStatusID,
             ISNULL(@ChangedByUserProfileID, ERM.fn_SystemUserID()), @ChangedByUserName,
             @Now, @MinutesInFrom, @Comments, @IsCustomerVisible,
             ISNULL(@ChangedByUserProfileID, ERM.fn_SystemUserID()));

        UPDATE t
           SET t.StatusID            = @ToStatusID,
               t.LastStatusChangeUtc = @Now,

               /* First response: the first time anybody who is not the reporter
                  acts on the ticket.  Set once, never overwritten. */
               /* ReportedByUserProfileID is NOT NULL, so this no longer needs
                  a sentinel to stop a NULL comparison swallowing the case. */
               t.FirstResponseUtc = COALESCE(t.FirstResponseUtc,
                                        CASE WHEN @ChangedByUserProfileID IS NULL
                                               OR @ChangedByUserProfileID <> t.ReportedByUserProfileID
                                             THEN @Now END),

               t.AssignedUtc      = CASE WHEN @ToStatusID = 2 AND t.AssignedUtc IS NULL THEN @Now ELSE t.AssignedUtc END,
               t.ResolvedUtc      = CASE WHEN @ToStatusID = 5 THEN @Now
                                         WHEN @ToStatusID = 8 THEN NULL   -- reopened: clear it
                                         ELSE t.ResolvedUtc END,
               t.ClosedUtc        = CASE WHEN @ToIsTerminal = 1 THEN @Now
                                         WHEN @ToStatusID = 8 THEN NULL
                                         ELSE t.ClosedUtc END,

               t.AssignedToUserProfileID = COALESCE(@AssignToUserProfileID, t.AssignedToUserProfileID),
               t.AssignedToUserName = COALESCE(@AssignToUserName, t.AssignedToUserName),
               t.UpdatedBy          = ISNULL(@ChangedByUserProfileID, ERM.fn_SystemUserID()),
               t.UpdatedDate        = GETUTCDATE(),

               t.ReopenCount      = t.ReopenCount + CASE WHEN @ToStatusID = 8 THEN 1 ELSE 0 END,

               t.ResolutionCode   = COALESCE(@ResolutionCode, t.ResolutionCode),
               t.ResolutionNotes  = COALESCE(@ResolutionNotes, t.ResolutionNotes),

               /* Total elapsed is wall clock since creation. */
               t.TotalElapsedMinutes = DATEDIFF(MINUTE, t.CreatedUtc, @Now),

               /* Active processing excludes every minute already banked in a
                  paused status.  Computed incrementally so it stays correct
                  across any number of pause/resume cycles. */
               t.ActiveProcessingMinutes =
                    DATEDIFF(MINUTE, t.CreatedUtc, @Now)
                  - ISNULL((SELECT SUM(h.MinutesInFromStatus)
                            FROM ERM.ERM_TicketStatusHistory h
                            JOIN ERM.ERM_TicketStatus s ON s.StatusID = h.FromStatusID
                            WHERE h.ERM_TicketID = @ERM_TicketID AND s.IsPaused = 1), 0)
                  - CASE WHEN @FromIsPaused = 1 THEN @MinutesInFrom ELSE 0 END
          FROM ERM.ERM_Ticket t
         WHERE t.ERM_TicketID = @ERM_TicketID;

        /* SLA evaluation against the policy attached at creation time. */
        UPDATE t
           SET t.SlaFirstResponseBreached =
                    CASE WHEN p.FirstResponseMinutes IS NOT NULL
                          AND t.FirstResponseUtc IS NOT NULL
                          AND DATEDIFF(MINUTE, t.CreatedUtc, t.FirstResponseUtc) > p.FirstResponseMinutes
                         THEN 1 ELSE t.SlaFirstResponseBreached END,
               t.SlaResolutionBreached =
                    CASE WHEN p.ResolutionMinutes IS NOT NULL
                          AND t.ResolvedUtc IS NOT NULL
                          AND ISNULL(t.ActiveProcessingMinutes, DATEDIFF(MINUTE, t.CreatedUtc, t.ResolvedUtc)) > p.ResolutionMinutes
                         THEN 1 ELSE t.SlaResolutionBreached END
          FROM ERM.ERM_Ticket t
          JOIN ERM.ERM_SlaPolicy p ON p.ERM_SlaPolicyID = t.ERM_SlaPolicyID
         WHERE t.ERM_TicketID = @ERM_TicketID;

        /* The problem stops pointing at this ticket once it is closed, so a
           future occurrence opens a fresh one instead of reviving a dead ticket. */
        IF @ToIsTerminal = 1
            UPDATE ERM.ERM_ErrorFingerprint
               SET OpenTicketID = NULL,
                   TriageState  = CASE WHEN TriageState IN (N'new', N'acknowledged') THEN N'resolved' ELSE TriageState END
             WHERE ERM_ErrorFingerprintID = @ERM_ErrorFingerprintID AND OpenTicketID = @ERM_TicketID;
        ELSE IF @ToStatusID = 8   -- reopened
            UPDATE ERM.ERM_ErrorFingerprint
               SET OpenTicketID = @ERM_TicketID, TriageState = N'acknowledged'
             WHERE ERM_ErrorFingerprintID = @ERM_ErrorFingerprintID;

    COMMIT TRANSACTION;

    IF OBJECT_ID(N'ERM.usp_Notification_Enqueue', N'P') IS NOT NULL
    BEGIN
        DECLARE @NotifyReporter INT, @NotifyTicketNo VARCHAR(30), @NotifyStatus NVARCHAR(80);

        SELECT @NotifyReporter = t.ReportedByUserProfileID, @NotifyTicketNo = t.TicketNumber
        FROM ERM.ERM_Ticket t WHERE t.ERM_TicketID = @ERM_TicketID;

        SELECT @NotifyStatus = DisplayName FROM ERM.ERM_TicketStatus WHERE StatusID = @ToStatusID;

        EXEC ERM.usp_Notification_Enqueue
             @RecipientUserProfileID = @NotifyReporter,
             @EventKind    = N'status_changed',
             @ERM_TicketID = @ERM_TicketID,
             @TicketNumber = @NotifyTicketNo,
             @Title        = N'Your issue has been updated',
             /* The STATUS, never the comment. Internal comments exist and an
                internal one reaching the reporter through a notification would
                bypass the IsCustomerVisible flag that the panel respects. */
             @Body         = @NotifyStatus,
             @ActedByUserProfileID = @ChangedByUserProfileID;
    END

    SELECT @ERM_TicketID AS TicketId, @FromStatusID AS FromStatusID, @ToStatusID AS ToStatusID,
           @SeqNo AS SequenceNo, @MinutesInFrom AS MinutesInPreviousStatus;
END
GO

/* =============================================================================
   usp_Ticket_AddComment
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_AddComment
(
    @ERM_TicketID           BIGINT,
    @AuthorUserProfileID INT          = NULL,
    @AuthorUserName     NVARCHAR(200) = NULL,
    @AuthorRole         NVARCHAR(20)  = N'support',
    @CommentText        NVARCHAR(MAX),
    @IsCustomerVisible  BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM ERM.ERM_Ticket WHERE ERM_TicketID = @ERM_TicketID)
    BEGIN
        RAISERROR (N'Ticket %I64d does not exist.', 16, 1, @ERM_TicketID);
        RETURN;
    END

    INSERT ERM.ERM_TicketComment (ERM_TicketID, AuthorUserProfileID, AuthorUserName, AuthorRole, CommentText, IsCustomerVisible, CreatedBy)
    VALUES (@ERM_TicketID, ISNULL(@AuthorUserProfileID, ERM.fn_SystemUserID()), @AuthorUserName,
            @AuthorRole, @CommentText, @IsCustomerVisible,
            ISNULL(@AuthorUserProfileID, ERM.fn_SystemUserID()));

    DECLARE @CommentId BIGINT = SCOPE_IDENTITY();

    /* A support reply counts as the first response even without a status move. */
    IF @AuthorRole = N'support'
        UPDATE ERM.ERM_Ticket
           SET FirstResponseUtc = ISNULL(FirstResponseUtc, SYSUTCDATETIME())
         WHERE ERM_TicketID = @ERM_TicketID;

    /* Only a CUSTOMER-VISIBLE support reply is announced. An internal note is
       internal; notifying the reporter about one would leak it in the one place
       the IsCustomerVisible flag does not reach. */
    IF @AuthorRole = N'support' AND @IsCustomerVisible = 1
       AND OBJECT_ID(N'ERM.usp_Notification_Enqueue', N'P') IS NOT NULL
    BEGIN
        DECLARE @CmtReporter INT, @CmtTicketNo VARCHAR(30);
        SELECT @CmtReporter = t.ReportedByUserProfileID, @CmtTicketNo = t.TicketNumber
        FROM ERM.ERM_Ticket t WHERE t.ERM_TicketID = @ERM_TicketID;

        EXEC ERM.usp_Notification_Enqueue
             @RecipientUserProfileID = @CmtReporter,
             @EventKind    = N'support_comment',
             @ERM_TicketID = @ERM_TicketID,
             @TicketNumber = @CmtTicketNo,
             @Title        = N'Support has replied to your issue',
             @Body         = N'Open the issue to read the reply.',
             @ActedByUserProfileID = @AuthorUserProfileID;
    END

    SELECT @CommentId AS CommentId;
END
GO

/* =============================================================================
   Search / reporting procedures
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Error_Search
(
    @ErrorReference VARCHAR(30)   = NULL,
    @TicketNumber   VARCHAR(30)   = NULL,
    @UserName       NVARCHAR(200) = NULL,
    @ErpModule      NVARCHAR(100) = NULL,
    @Screen         NVARCHAR(200) = NULL,
    @Component      NVARCHAR(200) = NULL,
    @ApiEndpoint    NVARCHAR(400) = NULL,
    @ExceptionType  NVARCHAR(400) = NULL,
    @SqlErrorNumber INT           = NULL,
    @CategoryCode   NVARCHAR(40)  = NULL,
    @SeverityCode   NVARCHAR(20)  = NULL,
    @LayerCode      NVARCHAR(30)  = NULL,
    @Environment    NVARCHAR(40)  = NULL,
    @CorrelationID  UNIQUEIDENTIFIER = NULL,
    @ERM_ErrorFingerprintID  BIGINT        = NULL,
    @FromUtc        DATETIME2(3)  = NULL,
    @ToUtc          DATETIME2(3)  = NULL,
    @SearchText     NVARCHAR(200) = NULL,
    @MinOccurrences INT           = NULL,   -- filter on the FINGERPRINT count
    @PageNumber     INT = 1,
    @PageSize       INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize IS NULL OR @PageSize < 1  SET @PageSize = 50;
    IF @PageSize > 500 SET @PageSize = 500;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;

    /* Default to the last 30 days rather than scanning history: an unbounded
       default here is how a support console takes the ERP's SQL Server down. */
    IF @FromUtc IS NULL AND @ErrorReference IS NULL AND @TicketNumber IS NULL AND @CorrelationID IS NULL
        SET @FromUtc = DATEADD(DAY, -30, SYSUTCDATETIME());

    SELECT
        o.ERM_ErrorOccurrenceID AS OccurrenceId, o.ErrorReference, o.OccurredUtc, o.OccurredLocal,
        l.Code AS LayerCode, l.DisplayName AS LayerName,
        c.Code AS CategoryCode, c.DisplayName AS CategoryName,
        sv.Code AS SeverityCode, sv.DisplayName AS SeverityName, sv.RankOrder AS SeverityRank,
        o.ExceptionType, o.Message,
        o.ErpModule, o.Screen, o.Component, o.RouteUrl, o.ActionName, o.FormName, o.LovName,
        o.ApiApplication, o.ApiController, o.ApiAction, o.ApiEndpoint, o.HttpMethod, o.HttpStatusCode,
        o.SqlErrorNumber, o.SqlObjectName, o.SqlLineNumber,
        o.UserName, o.UserDisplayName, o.Environment, o.AppVersion,
        o.BrowserName, o.BrowserVersion, o.OsName,
        o.CorrelationID, o.RequestID,
        o.ERM_ErrorFingerprintID AS FingerprintId, f.FingerprintHash, f.OccurrenceCount AS FingerprintOccurrenceCount,
        f.DistinctUserCount, f.FirstSeenUtc, f.LastSeenUtc, f.TriageState,
        o.ERM_TicketID AS TicketId, tk.TicketNumber, ts.Code AS TicketStatusCode, ts.DisplayName AS TicketStatusName,
        COUNT(*) OVER () AS TotalRowCount
    FROM ERM.ERM_ErrorOccurrence o
    JOIN ERM.ERM_ErrorFingerprint f ON f.ERM_ErrorFingerprintID = o.ERM_ErrorFingerprintID
    JOIN ERM.ERM_AppLayer       l  ON l.LayerID    = o.LayerID
    JOIN ERM.ERM_ErrorCategory  c  ON c.CategoryID = o.CategoryID
    JOIN ERM.ERM_Severity       sv ON sv.SeverityID = o.SeverityID
    LEFT JOIN ERM.ERM_Ticket        tk ON tk.ERM_TicketID = o.ERM_TicketID
    LEFT JOIN ERM.ERM_TicketStatus  ts ON ts.StatusID = tk.StatusID
    WHERE (@ErrorReference IS NULL OR o.ErrorReference = @ErrorReference)
      AND (@TicketNumber   IS NULL OR tk.TicketNumber  = @TicketNumber)
      AND (@UserName       IS NULL OR o.UserName       = @UserName)
      AND (@ErpModule      IS NULL OR o.ErpModule      = @ErpModule)
      AND (@Screen         IS NULL OR o.Screen         = @Screen)
      AND (@Component      IS NULL OR o.Component      = @Component)
      AND (@ApiEndpoint    IS NULL OR o.ApiEndpoint LIKE @ApiEndpoint + N'%')
      AND (@ExceptionType  IS NULL OR o.ExceptionType LIKE N'%' + @ExceptionType + N'%')
      AND (@SqlErrorNumber IS NULL OR o.SqlErrorNumber = @SqlErrorNumber)
      AND (@CategoryCode   IS NULL OR c.Code  = @CategoryCode)
      AND (@SeverityCode   IS NULL OR sv.Code = @SeverityCode)
      AND (@LayerCode      IS NULL OR l.Code  = @LayerCode)
      AND (@Environment    IS NULL OR o.Environment   = @Environment)
      AND (@CorrelationID  IS NULL OR o.CorrelationID = @CorrelationID)
      AND (@ERM_ErrorFingerprintID  IS NULL OR o.ERM_ErrorFingerprintID = @ERM_ErrorFingerprintID)
      AND (@FromUtc        IS NULL OR o.OccurredUtc  >= @FromUtc)
      AND (@ToUtc          IS NULL OR o.OccurredUtc  <= @ToUtc)
      AND (@MinOccurrences IS NULL OR f.OccurrenceCount >= @MinOccurrences)
      AND (@SearchText     IS NULL OR o.Message LIKE N'%' + @SearchText + N'%'
                                   OR o.ExceptionType LIKE N'%' + @SearchText + N'%'
                                   OR o.Screen LIKE N'%' + @SearchText + N'%')
    ORDER BY o.OccurredUtc DESC, o.ERM_ErrorOccurrenceID DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);   -- widely varying predicates; a cached plan here is a trap
END
GO

/* Recurring-problem report: the "frequently occurring problems that should be
   permanently resolved" list the brief asked for.                             */
CREATE OR ALTER PROCEDURE ERM.usp_Error_RecurringProblems
(
    @FromUtc        DATETIME2(3) = NULL,
    @MinOccurrences INT = 5,
    @TopN           INT = 100
)
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromUtc IS NULL SET @FromUtc = DATEADD(DAY, -7, SYSUTCDATETIME());

    SELECT TOP (@TopN)
        f.ERM_ErrorFingerprintID AS FingerprintId, f.FingerprintHash, f.SignatureText,
        sv.Code AS SeverityCode, sv.DisplayName AS SeverityName,
        c.Code  AS CategoryCode, l.Code AS LayerCode,
        f.ExceptionType, f.NormalizedMessage,
        f.ErpModule, f.Screen, f.Component, f.ApiEndpoint, f.SqlObjectName,
        f.FirstSeenUtc, f.LastSeenUtc, f.TriageState,
        f.OccurrenceCount AS LifetimeOccurrences,
        w.WindowOccurrences, w.WindowDistinctUsers,
        f.OpenTicketID, tk.TicketNumber AS OpenTicketNumber
    FROM ERM.ERM_ErrorFingerprint f
    JOIN ERM.ERM_Severity      sv ON sv.SeverityID = f.SeverityID
    JOIN ERM.ERM_ErrorCategory c  ON c.CategoryID  = f.CategoryID
    JOIN ERM.ERM_AppLayer      l  ON l.LayerID     = f.LayerID
    LEFT JOIN ERM.ERM_Ticket   tk ON tk.ERM_TicketID   = f.OpenTicketID
    CROSS APPLY (
        SELECT COUNT_BIG(*) AS WindowOccurrences, COUNT(DISTINCT o.UserName) AS WindowDistinctUsers
        FROM ERM.ERM_ErrorOccurrence o
        WHERE o.ERM_ErrorFingerprintID = f.ERM_ErrorFingerprintID AND o.OccurredUtc >= @FromUtc
    ) w
    WHERE w.WindowOccurrences >= @MinOccurrences
      AND f.TriageState <> N'muted'
    ORDER BY w.WindowOccurrences DESC, sv.RankOrder ASC;
END
GO

/* Everything that happened under one correlation id, across all layers, in
   order.  This is the view that turns "the save button failed" into "Angular
   caught an HTTP 500, which was this .NET exception, which was this deadlock
   in usp_PostJournal".                                                         */
CREATE OR ALTER PROCEDURE ERM.usp_Error_GetCorrelationTrail
(
    @CorrelationID UNIQUEIDENTIFIER
)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT o.ERM_ErrorOccurrenceID, o.ErrorReference, o.OccurredUtc, o.ReceivedUtc,
           l.Code AS LayerCode, l.DisplayName AS LayerName, l.LayerID,
           c.Code AS CategoryCode, sv.Code AS SeverityCode,
           o.ExceptionType, o.Message,
           o.Component, o.Screen, o.ApiController, o.ApiAction, o.HttpStatusCode,
           o.SqlErrorNumber, o.SqlObjectName, o.SqlLineNumber,
           o.ParentOccurrenceID, o.RequestID,
           d.StackTrace, d.InnerExceptionChain, d.SqlStatementText
    FROM ERM.ERM_ErrorOccurrence o
    JOIN ERM.ERM_AppLayer      l  ON l.LayerID     = o.LayerID
    JOIN ERM.ERM_ErrorCategory c  ON c.CategoryID  = o.CategoryID
    JOIN ERM.ERM_Severity      sv ON sv.SeverityID = o.SeverityID
    LEFT JOIN ERM.ERM_ErrorOccurrenceDetail d ON d.ERM_ErrorOccurrenceID = o.ERM_ErrorOccurrenceID
    WHERE o.CorrelationID = @CorrelationID
    ORDER BY l.LayerID DESC, o.OccurredUtc ASC;   -- deepest layer first: the cause, then the symptom
END
GO

CREATE OR ALTER PROCEDURE ERM.usp_Ticket_Search
(
    @TicketNumber   VARCHAR(30)   = NULL,
    @StatusCode     NVARCHAR(40)  = NULL,
    @OnlyOpen       BIT           = NULL,
    @QueueCode      NVARCHAR(40)  = NULL,
    @SeverityCode   NVARCHAR(20)  = NULL,
    @ReportedBy     NVARCHAR(200) = NULL,
    @AssignedTo     NVARCHAR(200) = NULL,
    @ErpModule      NVARCHAR(100) = NULL,
    @Environment    NVARCHAR(40)  = NULL,
    @BreachedSlaOnly BIT          = NULL,
    @FromUtc        DATETIME2(3)  = NULL,
    @ToUtc          DATETIME2(3)  = NULL,
    @SearchText     NVARCHAR(200) = NULL,
    @PageNumber     INT = 1,
    @PageSize       INT = 50
)
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize IS NULL OR @PageSize < 1  SET @PageSize = 50;
    IF @PageSize > 500 SET @PageSize = 500;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;

    SELECT
        t.ERM_TicketID AS TicketId, t.TicketNumber, t.Title, t.CreatedVia,
        st.Code AS StatusCode, st.DisplayName AS StatusName, st.IsOpen, st.IsTerminal,
        sv.Code AS SeverityCode, sv.DisplayName AS SeverityName, sv.RankOrder AS SeverityRank,
        q.Code  AS QueueCode,  q.DisplayName AS QueueName,
        t.ReportedByUserName, t.AssignedToUserName, t.ErpModule, t.Environment,
        t.CreatedUtc, t.FirstResponseUtc, t.AssignedUtc, t.ResolvedUtc, t.ClosedUtc,
        /* For an open ticket the stored elapsed value is stale by definition -
           it was last written at the previous status change.  Compute the live
           value here so the console never shows a frozen clock. */
        CASE WHEN st.IsTerminal = 1 THEN t.TotalElapsedMinutes
             ELSE DATEDIFF(MINUTE, t.CreatedUtc, SYSUTCDATETIME()) END AS TotalElapsedMinutes,
        CASE WHEN st.IsTerminal = 1 THEN t.ActiveProcessingMinutes
             ELSE DATEDIFF(MINUTE, t.CreatedUtc, SYSUTCDATETIME())
                  - ISNULL((SELECT SUM(h.MinutesInFromStatus)
                            FROM ERM.ERM_TicketStatusHistory h
                            JOIN ERM.ERM_TicketStatus s2 ON s2.StatusID = h.FromStatusID
                            WHERE h.ERM_TicketID = t.ERM_TicketID AND s2.IsPaused = 1), 0)
                  - CASE WHEN st.IsPaused = 1 THEN DATEDIFF(MINUTE, t.LastStatusChangeUtc, SYSUTCDATETIME()) ELSE 0 END
        END AS ActiveProcessingMinutes,
        t.SlaFirstResponseBreached, t.SlaResolutionBreached,
        p.FirstResponseMinutes AS SlaFirstResponseTargetMinutes,
        p.ResolutionMinutes    AS SlaResolutionTargetMinutes,
        t.ReopenCount, t.LinkedOccurrenceCount,
        t.ERM_ErrorFingerprintID AS FingerprintId, o.ErrorReference AS PrimaryErrorReference,
        COUNT(*) OVER () AS TotalRowCount
    FROM ERM.ERM_Ticket t
    JOIN ERM.ERM_TicketStatus st ON st.StatusID = t.StatusID
    JOIN ERM.ERM_Severity     sv ON sv.SeverityID = t.SeverityID
    JOIN ERM.ERM_TicketQueue  q  ON q.ERM_TicketQueueID     = t.ERM_TicketQueueID
    LEFT JOIN ERM.ERM_SlaPolicy p ON p.ERM_SlaPolicyID = t.ERM_SlaPolicyID
    LEFT JOIN ERM.ERM_ErrorOccurrence o ON o.ERM_ErrorOccurrenceID = t.ERM_ErrorOccurrenceID
    WHERE (@TicketNumber IS NULL OR t.TicketNumber = @TicketNumber)
      AND (@StatusCode   IS NULL OR st.Code = @StatusCode)
      AND (@OnlyOpen     IS NULL OR st.IsOpen = @OnlyOpen)
      AND (@QueueCode    IS NULL OR q.Code  = @QueueCode)
      AND (@SeverityCode IS NULL OR sv.Code = @SeverityCode)
      AND (@ReportedBy   IS NULL OR t.ReportedByUserName = @ReportedBy)
      AND (@AssignedTo   IS NULL OR t.AssignedToUserName = @AssignedTo)
      AND (@ErpModule    IS NULL OR t.ErpModule   = @ErpModule)
      AND (@Environment  IS NULL OR t.Environment = @Environment)
      AND (@BreachedSlaOnly IS NULL OR @BreachedSlaOnly = 0
           OR t.SlaFirstResponseBreached = 1 OR t.SlaResolutionBreached = 1)
      AND (@FromUtc IS NULL OR t.CreatedUtc >= @FromUtc)
      AND (@ToUtc   IS NULL OR t.CreatedUtc <= @ToUtc)
      AND (@SearchText IS NULL OR t.Title LIKE N'%' + @SearchText + N'%'
                               OR t.TicketNumber LIKE N'%' + @SearchText + N'%'
                               OR t.UserDescription LIKE N'%' + @SearchText + N'%')
    ORDER BY sv.RankOrder ASC, t.CreatedUtc DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
END
GO

/* Full ticket view for the admin panel and for the end user's "track my
   ticket" screen.  @ForEndUser=1 filters to customer-visible history only and
   drops every diagnostic field.                                               */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_GetDetail
(
    @TicketNumber VARCHAR(30),
    @ForEndUser   BIT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ERM_TicketID BIGINT = (SELECT ERM_TicketID AS TicketId FROM ERM.ERM_Ticket WHERE TicketNumber = @TicketNumber);
    IF @ERM_TicketID IS NULL RETURN;

    /* 1: header */
    SELECT t.ERM_TicketID, t.TicketNumber, t.Title,
           CASE WHEN @ForEndUser = 1 THEN NULL ELSE t.UserDescription END AS UserDescription,
           st.Code AS StatusCode, st.DisplayName AS StatusName, st.IsOpen, st.IsTerminal,
           sv.Code AS SeverityCode, sv.DisplayName AS SeverityName,
           q.Code AS QueueCode, q.DisplayName AS QueueName,
           t.ReportedByUserName,
           CASE WHEN @ForEndUser = 1 THEN NULL ELSE t.AssignedToUserName END AS AssignedToUserName,
           t.ErpModule, t.Environment, t.CreatedVia,
           t.CreatedUtc, t.FirstResponseUtc, t.AssignedUtc, t.ResolvedUtc, t.ClosedUtc,
           /* Live, not stored.  TotalElapsedMinutes is only written when the
              status changes, so a ticket that was created an hour ago and not
              yet touched would report NULL - and the console would render an
              empty cell where the age of the oldest open ticket should be.
              Compute it here for anything not yet in a terminal status. */
           CASE WHEN st.IsTerminal = 1 THEN t.TotalElapsedMinutes
                ELSE DATEDIFF(MINUTE, t.CreatedUtc, SYSUTCDATETIME()) END AS TotalElapsedMinutes,
           CASE WHEN st.IsTerminal = 1 THEN t.ActiveProcessingMinutes
                ELSE DATEDIFF(MINUTE, t.CreatedUtc, SYSUTCDATETIME())
                     - ISNULL((SELECT SUM(h.MinutesInFromStatus)
                               FROM ERM.ERM_TicketStatusHistory h
                               JOIN ERM.ERM_TicketStatus s2 ON s2.StatusID = h.FromStatusID
                               WHERE h.ERM_TicketID = t.ERM_TicketID AND s2.IsPaused = 1), 0)
                     - CASE WHEN st.IsPaused = 1
                            THEN DATEDIFF(MINUTE, t.LastStatusChangeUtc, SYSUTCDATETIME())
                            ELSE 0 END
           END AS ActiveProcessingMinutes,
           t.SlaFirstResponseBreached, t.SlaResolutionBreached,
           t.ReopenCount, t.LinkedOccurrenceCount,
           t.ResolutionCode, t.ResolutionNotes,
           o.ErrorReference AS PrimaryErrorReference,
           CASE WHEN @ForEndUser = 1 THEN NULL ELSE t.ERM_ErrorFingerprintID END AS FingerprintId
    FROM ERM.ERM_Ticket t
    JOIN ERM.ERM_TicketStatus st ON st.StatusID = t.StatusID
    JOIN ERM.ERM_Severity     sv ON sv.SeverityID = t.SeverityID
    JOIN ERM.ERM_TicketQueue  q  ON q.ERM_TicketQueueID = t.ERM_TicketQueueID
    LEFT JOIN ERM.ERM_ErrorOccurrence o ON o.ERM_ErrorOccurrenceID = t.ERM_ErrorOccurrenceID
    WHERE t.ERM_TicketID = @ERM_TicketID;

    /* 2: status history - the audit trail */
    SELECT h.SequenceNo,
           fs.Code AS FromStatusCode, fs.DisplayName AS FromStatusName,
           ts.Code AS ToStatusCode,   ts.DisplayName AS ToStatusName,
           CASE WHEN @ForEndUser = 1 THEN NULL ELSE h.ChangedByUserName END AS ChangedByUserName,
           h.ChangedUtc, h.MinutesInFromStatus, h.Comments
    FROM ERM.ERM_TicketStatusHistory h
    LEFT JOIN ERM.ERM_TicketStatus fs ON fs.StatusID = h.FromStatusID
    JOIN ERM.ERM_TicketStatus ts      ON ts.StatusID = h.ToStatusID
    WHERE h.ERM_TicketID = @ERM_TicketID
      AND (@ForEndUser = 0 OR h.IsCustomerVisible = 1)
    ORDER BY h.SequenceNo;

    /* 3: comments */
    SELECT c.ERM_TicketCommentID, c.AuthorUserName, c.AuthorRole, c.CommentText, c.CreatedUtc
    FROM ERM.ERM_TicketComment c
    WHERE c.ERM_TicketID = @ERM_TicketID
      AND (@ForEndUser = 0 OR c.IsCustomerVisible = 1)
    ORDER BY c.CreatedUtc;

    /* 4: time in each status - the operational metric, derived from history */
    SELECT s.Code AS StatusCode, s.DisplayName AS StatusName,
           SUM(h.MinutesInFromStatus) AS MinutesInStatus,
           COUNT(*) AS TimesEntered
    FROM ERM.ERM_TicketStatusHistory h
    JOIN ERM.ERM_TicketStatus s ON s.StatusID = h.FromStatusID
    WHERE h.ERM_TicketID = @ERM_TicketID AND h.MinutesInFromStatus IS NOT NULL
    GROUP BY s.Code, s.DisplayName, s.RankOrder
    ORDER BY s.RankOrder;

    /* 5: linked occurrences - admin only */
    IF @ForEndUser = 0
        SELECT TOP 200 o.ERM_ErrorOccurrenceID, o.ErrorReference, o.OccurredUtc, o.UserName,
               o.Screen, o.Component, o.Message, li.LinkReason
        FROM ERM.ERM_TicketOccurrenceLink li
        JOIN ERM.ERM_ErrorOccurrence o ON o.ERM_ErrorOccurrenceID = li.ERM_ErrorOccurrenceID
        WHERE li.ERM_TicketID = @ERM_TicketID
        ORDER BY o.OccurredUtc DESC;
END
GO

/* Full diagnostic payload for one occurrence.  Admin only - the end user's
   modal never calls this.                                                     */
CREATE OR ALTER PROCEDURE ERM.usp_Error_GetDetail
(
    @ErrorReference VARCHAR(30)
)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT o.*, l.Code AS LayerCode, c.Code AS CategoryCode, sv.Code AS SeverityCode,
           d.StackTrace, d.InnerExceptionChain, d.RequestPayloadJson, d.ResponsePayloadJson,
           d.ValidationErrorsJson, d.BreadcrumbsJson, d.CustomDataJson, d.SqlStatementText,
           f.FingerprintHash, f.SignatureText, f.OccurrenceCount, f.DistinctUserCount,
           f.FirstSeenUtc, f.LastSeenUtc, f.TriageState,
           tk.TicketNumber
    FROM ERM.ERM_ErrorOccurrence o
    JOIN ERM.ERM_AppLayer      l  ON l.LayerID     = o.LayerID
    JOIN ERM.ERM_ErrorCategory c  ON c.CategoryID  = o.CategoryID
    JOIN ERM.ERM_Severity      sv ON sv.SeverityID = o.SeverityID
    JOIN ERM.ERM_ErrorFingerprint f ON f.ERM_ErrorFingerprintID = o.ERM_ErrorFingerprintID
    LEFT JOIN ERM.ERM_ErrorOccurrenceDetail d ON d.ERM_ErrorOccurrenceID = o.ERM_ErrorOccurrenceID
    LEFT JOIN ERM.ERM_Ticket tk ON tk.ERM_TicketID = o.ERM_TicketID
    WHERE o.ErrorReference = @ErrorReference;
END
GO

/* Dashboard counters for the admin landing page. */
CREATE OR ALTER PROCEDURE ERM.usp_Dashboard_Summary
(
    @FromUtc DATETIME2(3) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromUtc IS NULL SET @FromUtc = DATEADD(DAY, -7, SYSUTCDATETIME());

    SELECT
        (SELECT COUNT_BIG(*) FROM ERM.ERM_ErrorOccurrence WHERE OccurredUtc >= @FromUtc)       AS ErrorsInPeriod,
        (SELECT COUNT_BIG(*) FROM ERM.ERM_ErrorFingerprint WHERE LastSeenUtc >= @FromUtc)      AS DistinctProblemsInPeriod,
        (SELECT COUNT_BIG(*) FROM ERM.ERM_Ticket t JOIN ERM.ERM_TicketStatus s ON s.StatusID = t.StatusID
          WHERE s.IsOpen = 1)                                                                  AS OpenTickets,
        (SELECT COUNT_BIG(*) FROM ERM.ERM_Ticket t JOIN ERM.ERM_TicketStatus s ON s.StatusID = t.StatusID
          WHERE s.IsOpen = 1 AND (t.SlaFirstResponseBreached = 1 OR t.SlaResolutionBreached = 1)) AS OpenTicketsBreachingSla,
        (SELECT COUNT_BIG(*) FROM ERM.ERM_Ticket WHERE CreatedUtc >= @FromUtc)                 AS TicketsCreatedInPeriod,
        (SELECT COUNT_BIG(*) FROM ERM.ERM_DeadLetter WHERE ReceivedUtc >= @FromUtc)            AS CaptureFailuresInPeriod;

    /* Errors by layer */
    SELECT l.Code AS LayerCode, l.DisplayName AS LayerName, COUNT_BIG(*) AS ErrorCount
    FROM ERM.ERM_ErrorOccurrence o JOIN ERM.ERM_AppLayer l ON l.LayerID = o.LayerID
    WHERE o.OccurredUtc >= @FromUtc
    GROUP BY l.Code, l.DisplayName, l.LayerID ORDER BY l.LayerID;

    /* Errors by severity */
    SELECT sv.Code AS SeverityCode, sv.DisplayName AS SeverityName, COUNT_BIG(*) AS ErrorCount
    FROM ERM.ERM_ErrorOccurrence o JOIN ERM.ERM_Severity sv ON sv.SeverityID = o.SeverityID
    WHERE o.OccurredUtc >= @FromUtc
    GROUP BY sv.Code, sv.DisplayName, sv.RankOrder ORDER BY sv.RankOrder;

    /* Top modules */
    SELECT TOP 10 ISNULL(o.ErpModule, N'(unknown)') AS ErpModule, COUNT_BIG(*) AS ErrorCount
    FROM ERM.ERM_ErrorOccurrence o WHERE o.OccurredUtc >= @FromUtc
    GROUP BY o.ErpModule ORDER BY COUNT_BIG(*) DESC;
END
GO

/* Triage a problem: acknowledge, mark as known, mute the noise, add a note. */
CREATE OR ALTER PROCEDURE ERM.usp_Fingerprint_Triage
(
    @ERM_ErrorFingerprintID  BIGINT,
    @TriageState    NVARCHAR(20) = NULL,
    @MuteMinutes    INT = NULL,
    @Notes          NVARCHAR(MAX) = NULL,
    @ChangedByUserName NVARCHAR(200) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @TriageState IS NOT NULL
       AND @TriageState NOT IN (N'new', N'acknowledged', N'known_issue', N'muted', N'resolved')
    BEGIN
        RAISERROR (N'Unknown triage state "%s".', 16, 1, @TriageState);
        RETURN;
    END

    DECLARE @OldJson NVARCHAR(MAX) =
        (SELECT TriageState, MutedUntilUtc, Notes FROM ERM.ERM_ErrorFingerprint
         WHERE ERM_ErrorFingerprintID = @ERM_ErrorFingerprintID FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    UPDATE ERM.ERM_ErrorFingerprint
       SET TriageState   = COALESCE(@TriageState, TriageState),
           MutedUntilUtc = CASE WHEN @MuteMinutes IS NULL THEN MutedUntilUtc
                                WHEN @MuteMinutes <= 0 THEN NULL
                                ELSE DATEADD(MINUTE, @MuteMinutes, SYSUTCDATETIME()) END,
           Notes         = COALESCE(@Notes, Notes)
     WHERE ERM_ErrorFingerprintID = @ERM_ErrorFingerprintID;

    INSERT ERM.ERM_ConfigAudit (TableName, KeyValue, Operation, OldValuesJson, NewValuesJson,
                                ChangedByUserProfileID, ChangedByUserName, CreatedBy)
    SELECT N'ErrorFingerprint', CONVERT(NVARCHAR(200), @ERM_ErrorFingerprintID), 'UPDATE', @OldJson,
           (SELECT TriageState, MutedUntilUtc, Notes FROM ERM.ERM_ErrorFingerprint
            WHERE ERM_ErrorFingerprintID = @ERM_ErrorFingerprintID FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           ISNULL(@ChangedByUserProfileID, ERM.fn_SystemUserID()), @ChangedByUserName,
           ISNULL(@ChangedByUserProfileID, ERM.fn_SystemUserID());
END
GO

/* usp_Ticket_ListForUser DELIBERATELY LIVES IN 007, NOT HERE.

   An earlier version of this file defined it, and 007 redefined it with the
   AwaitingYourReply column. Two CREATE OR ALTER statements for one procedure,
   in two scripts, means whichever ran last wins - and re-running 004 on its own
   to pick up an unrelated change would silently revert the end-user panel to
   the older definition.

   Worse, this copy still matched ownership on a text user id and a user NAME.
   After the move to UserProfileID it referenced a column that no longer exists,
   so it would have failed at run time - on "My Tickets", for every user.

   One definition, in the script that owns the end-user surface. See
   007_end_user_ticket_access.sql. */

/* Configuration read by the API at startup / on cache expiry. */
CREATE OR ALTER PROCEDURE ERM.usp_Config_Get
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SettingKey, SettingValue, DataType FROM ERM.ERM_Setting;
    SELECT Scope, KeyName FROM ERM.ERM_RedactionAllowList WHERE IsActive = 1;
    SELECT SeverityID, Code, DisplayName, RankOrder FROM ERM.ERM_Severity WHERE IsActive = 1;
    SELECT CategoryID, Code, DisplayName, DefaultSeverityID FROM ERM.ERM_ErrorCategory WHERE IsActive = 1;
    SELECT LayerID, Code, DisplayName FROM ERM.ERM_AppLayer;
    SELECT StatusID, Code, DisplayName, RankOrder, IsOpen, IsTerminal, IsPaused
      FROM ERM.ERM_TicketStatus WHERE IsActive = 1;
    SELECT FromStatusID, ToStatusID, RequiresComment, RequiresAssignee
      FROM ERM.ERM_TicketStatusTransition WHERE IsActive = 1;
    SELECT ERM_TicketQueueID, Code, DisplayName, ErpModuleMatch, IsDefault FROM ERM.ERM_TicketQueue WHERE IsActive = 1;
END
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'004_programmability.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.0.0', ERM.fn_SystemUserID());
GO

GO

/* ==========================================================================
   SCRIPT: 005_retention_and_archive.sql
   ========================================================================== */
GO
PRINT '--- 005_retention_and_archive.sql ---';
GO

/* =============================================================================
   ERP Error Management Framework
   Script 005 - Archive tables and the retention job

   APPROACH
   --------
   Two-stage, configuration-driven, batched:

     hot table  --(ArchiveAfterDays)-->  *_Archive  --(PurgeAfterDays)-->  gone

   The archive tables are deliberately plain heaps with a single clustered index
   on the date, no foreign keys and no non-clustered indexes: they exist to be
   written fast and read rarely.  Put them on a cheaper filegroup if you have
   one (see the FILEGROUP note at the bottom).

   Every move runs in small batches inside its own transaction so the job never
   holds a long lock on a table the ERP is writing to.  The job is safe to kill
   at any point - the next run resumes where it stopped.

   Detail rows (the big NVARCHAR(MAX) payloads) age out first and fastest: after
   30 days you still want to know that an error happened 4,000 times, but almost
   nobody needs the 40 KB stack trace of occurrence #3,412.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ------------------------------------------------------- archive tables -- */
IF OBJECT_ID(N'ERM.ERM_ErrorOccurrence_Archive', N'U') IS NULL
BEGIN
    SELECT TOP 0 * INTO ERM.ERM_ErrorOccurrence_Archive FROM ERM.ERM_ErrorOccurrence;
    ALTER TABLE ERM.ERM_ErrorOccurrence_Archive ADD ArchivedUtc DATETIME2(3) NOT NULL
        CONSTRAINT DF_OccArchive_ArchivedUtc DEFAULT (SYSUTCDATETIME());
    CREATE CLUSTERED INDEX CX_OccArchive_OccurredUtc ON ERM.ERM_ErrorOccurrence_Archive (OccurredUtc);
    CREATE NONCLUSTERED INDEX IX_OccArchive_Reference ON ERM.ERM_ErrorOccurrence_Archive (ErrorReference);
END
GO

IF OBJECT_ID(N'ERM.ERM_ErrorOccurrenceDetail_Archive', N'U') IS NULL
BEGIN
    SELECT TOP 0 * INTO ERM.ERM_ErrorOccurrenceDetail_Archive FROM ERM.ERM_ErrorOccurrenceDetail;
    ALTER TABLE ERM.ERM_ErrorOccurrenceDetail_Archive ADD ArchivedUtc DATETIME2(3) NOT NULL
        CONSTRAINT DF_DetailArchive_ArchivedUtc DEFAULT (SYSUTCDATETIME());
    CREATE CLUSTERED INDEX CX_DetailArchive_OccurrenceId ON ERM.ERM_ErrorOccurrenceDetail_Archive (ERM_ErrorOccurrenceID);
END
GO

IF OBJECT_ID(N'ERM.ERM_Ticket_Archive', N'U') IS NULL
BEGIN
    SELECT TOP 0 * INTO ERM.ERM_Ticket_Archive FROM ERM.ERM_Ticket;
    ALTER TABLE ERM.ERM_Ticket_Archive ADD ArchivedUtc DATETIME2(3) NOT NULL
        CONSTRAINT DF_TicketArchive_ArchivedUtc DEFAULT (SYSUTCDATETIME());
    CREATE CLUSTERED INDEX CX_TicketArchive_ClosedUtc ON ERM.ERM_Ticket_Archive (ClosedUtc);
    CREATE NONCLUSTERED INDEX IX_TicketArchive_Number ON ERM.ERM_Ticket_Archive (TicketNumber);
END
GO

IF OBJECT_ID(N'ERM.ERM_TicketStatusHistory_Archive', N'U') IS NULL
BEGIN
    SELECT TOP 0 * INTO ERM.ERM_TicketStatusHistory_Archive FROM ERM.ERM_TicketStatusHistory;
    ALTER TABLE ERM.ERM_TicketStatusHistory_Archive ADD ArchivedUtc DATETIME2(3) NOT NULL
        CONSTRAINT DF_TSHArchive_ArchivedUtc DEFAULT (SYSUTCDATETIME());
    CREATE CLUSTERED INDEX CX_TSHArchive_Ticket ON ERM.ERM_TicketStatusHistory_Archive (ERM_TicketID, SequenceNo);
END
GO

IF OBJECT_ID(N'ERM.ERM_TicketComment_Archive', N'U') IS NULL
BEGIN
    SELECT TOP 0 * INTO ERM.ERM_TicketComment_Archive FROM ERM.ERM_TicketComment;
    ALTER TABLE ERM.ERM_TicketComment_Archive ADD ArchivedUtc DATETIME2(3) NOT NULL
        CONSTRAINT DF_TCArchive_ArchivedUtc DEFAULT (SYSUTCDATETIME());
    CREATE CLUSTERED INDEX CX_TCArchive_Ticket ON ERM.ERM_TicketComment_Archive (ERM_TicketID, ERM_TicketCommentID);
END
GO

/* ------------------------------------------------------------- run log --- */
IF OBJECT_ID(N'ERM.ERM_RetentionRunLog', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_RetentionRunLog
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_RetentionRunLog_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_RetentionRunLog_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_RetentionRunLog_AppNo DEFAULT (1),
        ERM_RetentionRunLogID           BIGINT          IDENTITY(1,1) NOT NULL,
        StartedUtc      DATETIME2(3)    NOT NULL CONSTRAINT DF_RetentionRun_Started DEFAULT (SYSUTCDATETIME()),
        FinishedUtc     DATETIME2(3)    NULL,
        DataSet         NVARCHAR(40)    NOT NULL,
        RowsArchived    BIGINT          NOT NULL CONSTRAINT DF_RetentionRun_Archived DEFAULT (0),
        RowsPurged      BIGINT          NOT NULL CONSTRAINT DF_RetentionRun_Purged   DEFAULT (0),
        Succeeded       BIT             NOT NULL CONSTRAINT DF_RetentionRun_Succeeded DEFAULT (0),
        ErrorMessage    NVARCHAR(MAX)   NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_RetentionRunLog_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_RetentionRunLog_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_RetentionRunLog_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_RetentionRunLog PRIMARY KEY CLUSTERED (ERM_RetentionRunLogID)
    );
END
GO

/* =============================================================================
   usp_Retention_Apply
   -----------------------------------------------------------------------------
   Run nightly from SQL Agent (or from the API's scheduler if Agent is not
   available on your edition).  @WhatIf = 1 reports what would move and changes
   nothing - run that first on production.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Retention_Apply
(
    @DataSet        NVARCHAR(40) = NULL,   -- NULL = every active policy
    @WhatIf         BIT = 0,
    @MaxBatches     INT = 200              -- hard stop so one run cannot go all night
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    DECLARE @policies TABLE (DataSet NVARCHAR(40), ArchiveAfterDays INT, PurgeAfterDays INT, BatchSize INT);
    INSERT @policies
    SELECT DataSet, ArchiveAfterDays, PurgeAfterDays, BatchSize
    FROM ERM.ERM_RetentionPolicy
    WHERE IsActive = 1 AND (@DataSet IS NULL OR DataSet = @DataSet);

    DECLARE @ds NVARCHAR(40), @archDays INT, @purgeDays INT, @batch INT;
    DECLARE @cutoff DATETIME2(3), @purgeCutoff DATETIME2(3);
    DECLARE @rows INT, @totalArchived BIGINT, @totalPurged BIGINT, @batches INT, @ERM_RetentionRunLogID BIGINT;

    /* Declared here, not inside the loops: T-SQL DECLARE is batch-scoped, so a
       DECLARE that executes a second time raises "variable already declared". */
    DECLARE @moving  TABLE (ERM_ErrorOccurrenceID BIGINT PRIMARY KEY);
    DECLARE @movingT TABLE (ERM_TicketID     BIGINT PRIMARY KEY);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT DataSet, ArchiveAfterDays, PurgeAfterDays, BatchSize FROM @policies;
    OPEN cur;
    FETCH NEXT FROM cur INTO @ds, @archDays, @purgeDays, @batch;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @totalArchived = 0; SET @totalPurged = 0; SET @batches = 0;
        SET @cutoff      = CASE WHEN @archDays  > 0 THEN DATEADD(DAY, -@archDays,  @Now) END;
        SET @purgeCutoff = CASE WHEN @purgeDays > 0 THEN DATEADD(DAY, -@purgeDays, @Now) END;

        /* A scheduled job has no ERP user behind it. */
        INSERT ERM.ERM_RetentionRunLog (DataSet, CreatedBy) VALUES (@ds, ERM.fn_SystemUserID());
        SET @ERM_RetentionRunLogID = SCOPE_IDENTITY();

        BEGIN TRY
            /* ============================ occurrence_detail ================ */
            IF @ds = N'occurrence_detail' AND @cutoff IS NOT NULL
            BEGIN
                IF @WhatIf = 1
                BEGIN
                    SELECT @ds AS DataSet, COUNT_BIG(*) AS RowsThatWouldArchive
                    FROM ERM.ERM_ErrorOccurrenceDetail d
                    JOIN ERM.ERM_ErrorOccurrence o ON o.ERM_ErrorOccurrenceID = d.ERM_ErrorOccurrenceID
                    WHERE o.OccurredUtc < @cutoff;
                END
                ELSE
                BEGIN
                    SET @rows = 1;
                    WHILE @rows > 0 AND @batches < @MaxBatches
                    BEGIN
                        BEGIN TRANSACTION;
                            /* DELETE ... OUTPUT INTO moves the rows in one pass:
                               no window where a row exists in both tables, and
                               no second read of the NVARCHAR(MAX) payloads. */
                            DELETE TOP (@batch) d
                            OUTPUT deleted.ERM_ErrorOccurrenceID, deleted.StackTrace, deleted.InnerExceptionChain,
                                   deleted.RequestPayloadJson, deleted.ResponsePayloadJson,
                                   deleted.ValidationErrorsJson, deleted.BreadcrumbsJson,
                                   deleted.CustomDataJson, deleted.SqlStatementText, @Now
                            INTO ERM.ERM_ErrorOccurrenceDetail_Archive
                                 (ERM_ErrorOccurrenceID, StackTrace, InnerExceptionChain, RequestPayloadJson,
                                  ResponsePayloadJson, ValidationErrorsJson, BreadcrumbsJson,
                                  CustomDataJson, SqlStatementText, ArchivedUtc)
                            FROM ERM.ERM_ErrorOccurrenceDetail d
                            WHERE EXISTS (SELECT 1 FROM ERM.ERM_ErrorOccurrence o
                                          WHERE o.ERM_ErrorOccurrenceID = d.ERM_ErrorOccurrenceID AND o.OccurredUtc < @cutoff);
                            SET @rows = @@ROWCOUNT;
                        COMMIT TRANSACTION;
                        SET @totalArchived += @rows;
                        SET @batches += 1;
                    END
                END

                IF @purgeCutoff IS NOT NULL AND @WhatIf = 0
                BEGIN
                    SET @rows = 1; SET @batches = 0;
                    WHILE @rows > 0 AND @batches < @MaxBatches
                    BEGIN
                        DELETE TOP (@batch) FROM ERM.ERM_ErrorOccurrenceDetail_Archive
                        WHERE ArchivedUtc < @purgeCutoff;
                        SET @rows = @@ROWCOUNT; SET @totalPurged += @rows; SET @batches += 1;
                    END
                END
            END

            /* ================================ occurrence =================== */
            /* Order matters: the detail row must be gone (archived or purged)
               before its occurrence can move, because of the FK.              */
            IF @ds = N'occurrence' AND @cutoff IS NOT NULL
            BEGIN
                IF @WhatIf = 1
                BEGIN
                    SELECT @ds AS DataSet, COUNT_BIG(*) AS RowsThatWouldArchive
                    FROM ERM.ERM_ErrorOccurrence o
                    WHERE o.OccurredUtc < @cutoff AND o.ERM_TicketID IS NULL;
                END
                ELSE
                BEGIN
                    SET @rows = 1;
                    WHILE @rows > 0 AND @batches < @MaxBatches
                    BEGIN
                        BEGIN TRANSACTION;
                            DELETE @moving;

                            INSERT @moving (ERM_ErrorOccurrenceID)
                            SELECT TOP (@batch) o.ERM_ErrorOccurrenceID
                            FROM ERM.ERM_ErrorOccurrence o
                            WHERE o.OccurredUtc < @cutoff
                              /* An occurrence attached to a ticket is evidence.
                                 It ages out with its ticket, not on its own. */
                              AND o.ERM_TicketID IS NULL
                              /* Never orphan a child that is still hot. */
                              AND NOT EXISTS (SELECT 1 FROM ERM.ERM_ErrorOccurrence ch
                                              WHERE ch.ParentOccurrenceID = o.ERM_ErrorOccurrenceID)
                            ORDER BY o.OccurredUtc;

                            SET @rows = @@ROWCOUNT;

                            IF @rows > 0
                            BEGIN
                                DELETE d FROM ERM.ERM_ErrorOccurrenceDetail d
                                JOIN @moving m ON m.ERM_ErrorOccurrenceID = d.ERM_ErrorOccurrenceID;

                                DELETE li FROM ERM.ERM_TicketOccurrenceLink li
                                JOIN @moving m ON m.ERM_ErrorOccurrenceID = li.ERM_ErrorOccurrenceID;

                                INSERT ERM.ERM_ErrorOccurrence_Archive
                                SELECT o.*, @Now FROM ERM.ERM_ErrorOccurrence o
                                JOIN @moving m ON m.ERM_ErrorOccurrenceID = o.ERM_ErrorOccurrenceID;

                                DELETE o FROM ERM.ERM_ErrorOccurrence o
                                JOIN @moving m ON m.ERM_ErrorOccurrenceID = o.ERM_ErrorOccurrenceID;
                            END
                        COMMIT TRANSACTION;
                        SET @totalArchived += @rows;
                        SET @batches += 1;
                    END
                END

                IF @purgeCutoff IS NOT NULL AND @WhatIf = 0
                BEGIN
                    SET @rows = 1; SET @batches = 0;
                    WHILE @rows > 0 AND @batches < @MaxBatches
                    BEGIN
                        DELETE TOP (@batch) FROM ERM.ERM_ErrorOccurrence_Archive WHERE OccurredUtc < @purgeCutoff;
                        SET @rows = @@ROWCOUNT; SET @totalPurged += @rows; SET @batches += 1;
                    END
                END
            END

            /* ==================================== ticket =================== */
            IF @ds = N'ticket' AND @cutoff IS NOT NULL AND @WhatIf = 0
            BEGIN
                SET @rows = 1;
                WHILE @rows > 0 AND @batches < @MaxBatches
                BEGIN
                    BEGIN TRANSACTION;
                        DELETE @movingT;

                        INSERT @movingT (ERM_TicketID)
                        SELECT TOP (@batch) t.ERM_TicketID
                        FROM ERM.ERM_Ticket t
                        JOIN ERM.ERM_TicketStatus s ON s.StatusID = t.StatusID
                        WHERE s.IsTerminal = 1 AND t.ClosedUtc IS NOT NULL AND t.ClosedUtc < @cutoff
                        ORDER BY t.ClosedUtc;

                        SET @rows = @@ROWCOUNT;

                        IF @rows > 0
                        BEGIN
                            INSERT ERM.ERM_TicketStatusHistory_Archive
                            SELECT h.*, @Now FROM ERM.ERM_TicketStatusHistory h
                            JOIN @movingT m ON m.ERM_TicketID = h.ERM_TicketID;

                            INSERT ERM.ERM_TicketComment_Archive
                            SELECT c.*, @Now FROM ERM.ERM_TicketComment c
                            JOIN @movingT m ON m.ERM_TicketID = c.ERM_TicketID;

                            INSERT ERM.ERM_Ticket_Archive
                            SELECT t.*, @Now FROM ERM.ERM_Ticket t
                            JOIN @movingT m ON m.ERM_TicketID = t.ERM_TicketID;

                            /* Release every reference before deleting the ticket. */
                            UPDATE o SET ERM_TicketID = NULL
                            FROM ERM.ERM_ErrorOccurrence o
                            JOIN @movingT m ON m.ERM_TicketID = o.ERM_TicketID;

                            UPDATE f SET OpenTicketID = NULL
                            FROM ERM.ERM_ErrorFingerprint f
                            JOIN @movingT m ON m.ERM_TicketID = f.OpenTicketID;

                            DELETE li FROM ERM.ERM_TicketOccurrenceLink li
                            JOIN @movingT m ON m.ERM_TicketID = li.ERM_TicketID;

                            /* TicketStatusHistory and TicketComment cascade. */
                            DELETE t FROM ERM.ERM_Ticket t JOIN @movingT m ON m.ERM_TicketID = t.ERM_TicketID;
                        END
                    COMMIT TRANSACTION;
                    SET @totalArchived += @rows;
                    SET @batches += 1;
                END
            END

            /* ===================================== audit =================== */
            IF @ds = N'audit' AND @cutoff IS NOT NULL AND @WhatIf = 0
            BEGIN
                SET @rows = 1;
                WHILE @rows > 0 AND @batches < @MaxBatches
                BEGIN
                    DELETE TOP (@batch) FROM ERM.ERM_ConfigAudit WHERE ChangedUtc < @cutoff;
                    SET @rows = @@ROWCOUNT; SET @totalPurged += @rows; SET @batches += 1;
                END
                SET @rows = 1; SET @batches = 0;
                WHILE @rows > 0 AND @batches < @MaxBatches
                BEGIN
                    DELETE TOP (@batch) FROM ERM.ERM_DeadLetter WHERE ReceivedUtc < @cutoff;
                    SET @rows = @@ROWCOUNT; SET @totalPurged += @rows; SET @batches += 1;
                END
            END

            UPDATE ERM.ERM_RetentionRunLog
               SET FinishedUtc = SYSUTCDATETIME(), RowsArchived = @totalArchived,
                   RowsPurged = @totalPurged, Succeeded = 1
             WHERE ERM_RetentionRunLogID = @ERM_RetentionRunLogID;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            UPDATE ERM.ERM_RetentionRunLog
               SET FinishedUtc = SYSUTCDATETIME(), RowsArchived = @totalArchived,
                   RowsPurged = @totalPurged, Succeeded = 0, ErrorMessage = ERROR_MESSAGE()
             WHERE ERM_RetentionRunLogID = @ERM_RetentionRunLogID;
        END CATCH

        FETCH NEXT FROM cur INTO @ds, @archDays, @purgeDays, @batch;
    END
    CLOSE cur; DEALLOCATE cur;

    SELECT DataSet, StartedUtc, FinishedUtc, RowsArchived, RowsPurged, Succeeded, ErrorMessage
    FROM ERM.ERM_RetentionRunLog
    WHERE StartedUtc >= @Now
    ORDER BY ERM_RetentionRunLogID;
END
GO

/* Unified read across hot + archive, for the rare "find that error from last
   year" case.  Deliberately a view and not the default search path.          */
CREATE OR ALTER VIEW ERM.vw_ErrorOccurrence_All
AS
    SELECT CONVERT(BIT,0) AS IsArchived, o.ERM_ErrorOccurrenceID, o.ErrorReference, o.ERM_ErrorFingerprintID,
           o.OccurredUtc, o.LayerID, o.CategoryID, o.SeverityID, o.ExceptionType, o.Message,
           o.ErpModule, o.Screen, o.Component, o.ApiEndpoint, o.SqlErrorNumber, o.SqlObjectName,
           o.UserName, o.CorrelationID, o.Environment, o.ERM_TicketID
    FROM ERM.ERM_ErrorOccurrence o
    UNION ALL
    SELECT CONVERT(BIT,1) AS IsArchived, a.ERM_ErrorOccurrenceID, a.ErrorReference, a.ERM_ErrorFingerprintID,
           a.OccurredUtc, a.LayerID, a.CategoryID, a.SeverityID, a.ExceptionType, a.Message,
           a.ErpModule, a.Screen, a.Component, a.ApiEndpoint, a.SqlErrorNumber, a.SqlObjectName,
           a.UserName, a.CorrelationID, a.Environment, a.ERM_TicketID
    FROM ERM.ERM_ErrorOccurrence_Archive a;
GO

/* -----------------------------------------------------------------------------
   OPTIONAL: filegroup placement
   -----------------------------------------------------------------------------
   If the ERP database has a secondary filegroup on cheaper storage, move the
   archive tables there.  Run once, out of hours:

       ALTER DATABASE [YourErpDb] ADD FILEGROUP FG_ErrArchive;
       ALTER DATABASE [YourErpDb] ADD FILE
           (NAME = N'ErrArchive1', FILENAME = N'E:\SQLData\ErrArchive1.ndf',
            SIZE = 512MB, FILEGROWTH = 256MB) TO FILEGROUP FG_ErrArchive;

       CREATE CLUSTERED INDEX CX_OccArchive_OccurredUtc
           ON ERM.ERM_ErrorOccurrence_Archive (OccurredUtc)
           WITH (DROP_EXISTING = ON, ONLINE = ON) ON FG_ErrArchive;

   On Enterprise/Developer edition the hot ErrorOccurrence table is a good
   candidate for monthly partitioning on OccurredUtc, which turns the archive
   step into a metadata-only SWITCH.  Not assumed here because it needs an
   edition guarantee I do not have.
   ----------------------------------------------------------------------------- */

/* -----------------------------------------------------------------------------
   SQL Agent job (create once per environment).
   -----------------------------------------------------------------------------
       EXEC msdb.dbo.sp_add_job @job_name = N'ERP Error Mgmt - Retention';
       EXEC msdb.dbo.sp_add_jobstep
            @job_name = N'ERP Error Mgmt - Retention',
            @step_name = N'Apply retention policies',
            @subsystem = N'TSQL',
            @database_name = N'YourErpDb',
            @command = N'EXEC ERM.usp_Retention_Apply;';
       EXEC msdb.dbo.sp_add_jobschedule
            @job_name = N'ERP Error Mgmt - Retention',
            @name = N'Nightly 02:15',
            @freq_type = 4, @freq_interval = 1, @active_start_time = 021500;
       EXEC msdb.dbo.sp_add_jobserver @job_name = N'ERP Error Mgmt - Retention';
   ----------------------------------------------------------------------------- */

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'005_retention_and_archive.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.0.0', ERM.fn_SystemUserID());
GO

GO

/* ==========================================================================
   SCRIPT: 006_security.sql
   ========================================================================== */
GO
PRINT '--- 006_security.sql ---';
GO

/* =============================================================================
   ERP Error Management Framework
   Script 006 - Least-privilege database security

   The ERP application login gets EXECUTE on the ERM schema and NOTHING
   else: no SELECT, no INSERT, no table rights at all.  A SQL-injection hole
   anywhere in the ERP therefore cannot read the error store, and the error
   store's own procedures are the only way in.

   Edit the two variables below before running.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @AppUser   SYSNAME = N'erp_app';        -- <-- the ERP's existing database user
DECLARE @AdminRole SYSNAME = N'ERM_admin';  -- support/admin console role

DECLARE @sql NVARCHAR(MAX);

/* ------------------------------------------------- application privileges -- */
IF DATABASE_PRINCIPAL_ID(@AppUser) IS NOT NULL
BEGIN
    SET @sql = N'GRANT EXECUTE ON SCHEMA::ERM TO ' + QUOTENAME(@AppUser) + N';';
    EXEC sp_executesql @sql;

    /* Deny the blanket table rights the app might inherit from db_datareader,
       so a future "GRANT db_datareader" cannot silently open the error store. */
    SET @sql = N'DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::ERM TO ' + QUOTENAME(@AppUser) + N';';
    EXEC sp_executesql @sql;

    PRINT N'Granted EXECUTE on ERM to ' + @AppUser;
END
ELSE
    PRINT N'WARNING: database principal "' + @AppUser + N'" not found - edit @AppUser and re-run.';
GO

/* ------------------------------------------------------- admin/support role */
DECLARE @AdminRole SYSNAME = N'ERM_admin';
DECLARE @sql NVARCHAR(MAX);

IF DATABASE_PRINCIPAL_ID(@AdminRole) IS NULL
BEGIN
    SET @sql = N'CREATE ROLE ' + QUOTENAME(@AdminRole) + N';';
    EXEC sp_executesql @sql;
END

SET @sql = N'GRANT EXECUTE ON SCHEMA::ERM TO ' + QUOTENAME(@AdminRole) + N';
             GRANT SELECT  ON SCHEMA::ERM TO ' + QUOTENAME(@AdminRole) + N';';
EXEC sp_executesql @sql;

/* Configuration is writable by the admin role; the error/ticket tables are not
   - those change only through the procedures, which is what keeps the audit
   trail complete. */
SET @sql = N'
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_Setting             TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_ErrorCategory       TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_Severity            TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_TicketStatus        TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_TicketStatusTransition TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_TicketQueue         TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_SlaPolicy           TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_AutoTicketRule      TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_RedactionAllowList  TO ' + QUOTENAME(@AdminRole) + N';
    GRANT INSERT, UPDATE, DELETE ON OBJECT::ERM.ERM_RetentionPolicy     TO ' + QUOTENAME(@AdminRole) + N';';
EXEC sp_executesql @sql;

PRINT N'Role ' + @AdminRole + N' configured.  Add your support staff with:';
PRINT N'    ALTER ROLE [ERM_admin] ADD MEMBER [<db user>];';
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'006_security.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.0.0', ERM.fn_SystemUserID());
GO

GO

/* ==========================================================================
   SCRIPT: 007_end_user_ticket_access.sql
   ========================================================================== */
GO
PRINT '--- 007_end_user_ticket_access.sql ---';
GO

/* =============================================================================
   ERP Error Management Framework
   Script 007 - End-user ticket access ("My Tickets")

   The procedures in 004 that serve the SUPPORT console assume the caller is
   support staff.  These three serve the END USER, and the difference is not
   cosmetic: ownership is enforced HERE, in SQL, so that no API route, no
   controller and no future caller can forget to check it.

   The rule throughout: a ticket that exists but belongs to someone else is
   indistinguishable from one that does not exist.  Returning 403 for the former
   and 404 for the latter would turn sequential ticket numbers into an
   enumeration oracle - TKT-2026-00000001 upward, until you learn how many
   tickets the company has and which numbers are real.

   Idempotent: yes.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* -----------------------------------------------------------------------------
   Ownership predicate, in one place.

   Ownership is the ERP UserProfileID and nothing else. An earlier draft also
   matched on user NAME, to survive a token-format migration. That is the wrong
   trade for an authorisation predicate: a display name is not unique, is not
   stable, and is editable - so "or the names match" is a second, weaker door
   into somebody else's ticket. One key, and it is the ERP's own.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION ERM.fn_UserOwnsTicket
(
    @ERM_TicketID   BIGINT,
    @UserProfileID  INT
)
RETURNS BIT
AS
BEGIN
    /* No identity supplied = owns nothing. NULL is an anonymous caller and -1
       is the non-user value; if -1 could own tickets, every anonymous caller
       would own every ticket raised from a public page. */
    IF @UserProfileID IS NULL OR @UserProfileID <= 0 RETURN 0;

    IF EXISTS (
        SELECT 1 FROM ERM.ERM_Ticket t
        WHERE t.ERM_TicketID = @ERM_TicketID
          AND t.ReportedByUserProfileID = @UserProfileID
    )
        RETURN 1;

    RETURN 0;
END
GO

/* =============================================================================
   usp_Ticket_ListForUser  (REPLACES the version in 004)
   -----------------------------------------------------------------------------
   Adds AwaitingYourReply, which is what makes the panel actionable rather than
   informational: it tells the user that support is blocked on THEM.  Derived
   from the ticket sitting in a paused status, which is exactly what
   "Waiting for Information" is flagged as in ERM.ERM_TicketStatus.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_ListForUser
(
    @UserProfileID INT = NULL,
    @OnlyOpen   BIT = 0,
    @PageNumber INT = 1,
    @PageSize   INT = 25
)
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 25;
    IF @PageSize > 200 SET @PageSize = 200;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;

    /* No identity, no rows.  Deliberately not an error: an unauthenticated
       caller asking for "my tickets" has none, which is a valid answer. */
    IF @UserProfileID IS NULL OR @UserProfileID <= 0 RETURN;

    SELECT t.TicketNumber, t.Title,
           st.Code AS StatusCode, st.DisplayName AS StatusName, st.IsOpen,
           sv.DisplayName AS SeverityName,
           t.CreatedUtc, t.ResolvedUtc, t.ClosedUtc,
           t.ErpModule,

           /* The most recent thing the user is allowed to see, whether it came
              from a status change or from a support comment.  Two sources, one
              column, because the user does not care which table it lived in. */
           (SELECT TOP 1 x.Note FROM (
                SELECT h.Comments AS Note, h.ChangedUtc AS At
                FROM ERM.ERM_TicketStatusHistory h
                WHERE h.ERM_TicketID = t.ERM_TicketID
                  AND h.IsCustomerVisible = 1
                  AND h.Comments IS NOT NULL
                UNION ALL
                SELECT c.CommentText, c.CreatedUtc
                FROM ERM.ERM_TicketComment c
                WHERE c.ERM_TicketID = t.ERM_TicketID
                  AND c.IsCustomerVisible = 1
                  AND c.AuthorRole <> N'reporter'
            ) x ORDER BY x.At DESC) AS LatestUpdate,

           /* Support is blocked on the user. */
           CONVERT(BIT, CASE WHEN st.IsPaused = 1 THEN 1 ELSE 0 END) AS AwaitingYourReply,

           COUNT(*) OVER () AS TotalRowCount
    FROM ERM.ERM_Ticket t
    JOIN ERM.ERM_TicketStatus st ON st.StatusID = t.StatusID
    JOIN ERM.ERM_Severity     sv ON sv.SeverityID = t.SeverityID
    WHERE t.ReportedByUserProfileID = @UserProfileID
      AND (@OnlyOpen = 0 OR st.IsOpen = 1)
    ORDER BY
        /* Anything waiting on the user comes first - it is the only row in the
           list they can actually do something about. */
        CASE WHEN st.IsPaused = 1 THEN 0 ELSE 1 END,
        t.CreatedUtc DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

/* =============================================================================
   usp_Ticket_GetForUser
   -----------------------------------------------------------------------------
   The end user's view of ONE of their own tickets.

   Distinct from usp_Ticket_GetDetail @ForEndUser = 1 for one reason that
   matters: that procedure nulls the diagnostic COLUMNS but does not check
   OWNERSHIP - it was written for a support console where the caller is already
   trusted.  Calling it from an end-user route would let any authenticated user
   read any ticket by number.  This procedure enforces ownership first and
   returns nothing at all if the check fails.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_GetForUser
(
    @TicketNumber VARCHAR(30),
    @UserProfileID INT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ERM_TicketID BIGINT =
        (SELECT ERM_TicketID AS TicketId FROM ERM.ERM_Ticket WHERE TicketNumber = @TicketNumber);

    /* Not found and not yours return the same thing: nothing.  The caller
       cannot tell them apart, which is the point. */
    IF @ERM_TicketID IS NULL RETURN;
    IF ERM.fn_UserOwnsTicket(@ERM_TicketID, @UserProfileID) = 0 RETURN;

    /* ---- 1: header, end-user fields only -------------------------------- */
    SELECT
        t.TicketNumber,
        t.Title,
        st.Code AS StatusCode,
        st.DisplayName AS StatusName,
        st.IsOpen,
        sv.DisplayName AS SeverityName,
        t.ErpModule,
        t.CreatedUtc,
        t.FirstResponseUtc,
        t.ResolvedUtc,
        t.ClosedUtc,
        o.ErrorReference,
        /* Their OWN words are shown back to them - unlike the support view,
           where UserDescription is hidden from the end user because it is
           shown here instead, labelled as theirs. */
        t.UserDescription AS YourDescription,
        /* The resolution, if support wrote one and the ticket is resolved.
           Withheld while still open: a half-written resolution note read as a
           promise is worse than no note. */
        CASE WHEN st.IsTerminal = 1 OR t.ResolvedUtc IS NOT NULL
             THEN t.ResolutionNotes END AS ResolutionNotes,
        CONVERT(BIT, CASE WHEN st.IsPaused = 1 THEN 1 ELSE 0 END) AS AwaitingYourReply,
        /* A closed ticket is read-only.  Letting a user comment on it would
           create a conversation nobody is watching. */
        CONVERT(BIT, CASE WHEN st.IsTerminal = 1 THEN 0 ELSE 1 END) AS CanComment
        /* Deliberately NOT selected: AssignedToUserName, ERM_ErrorFingerprintID,
           SlaFirstResponseBreached, SlaResolutionBreached, TotalElapsedMinutes,
           ActiveProcessingMinutes, ReopenCount, LinkedOccurrenceCount, Queue.
           SLA breach and elapsed metrics in particular are internal
           performance data; showing a user that their ticket has breached its
           SLA invites a conversation support has not agreed to have. */
    FROM ERM.ERM_Ticket t
    JOIN ERM.ERM_TicketStatus st ON st.StatusID = t.StatusID
    JOIN ERM.ERM_Severity     sv ON sv.SeverityID = t.SeverityID
    LEFT JOIN ERM.ERM_ErrorOccurrence o ON o.ERM_ErrorOccurrenceID = t.ERM_ErrorOccurrenceID
    WHERE t.ERM_TicketID = @ERM_TicketID;

    /* ---- 2: customer-visible status history ----------------------------- */
    SELECT h.SequenceNo,
           ts.DisplayName AS StatusName,
           h.ChangedUtc,
           h.Comments
           /* ChangedByUserName omitted: which support engineer touched the
              ticket is internal. */
    FROM ERM.ERM_TicketStatusHistory h
    JOIN ERM.ERM_TicketStatus ts ON ts.StatusID = h.ToStatusID
    WHERE h.ERM_TicketID = @ERM_TicketID
      AND h.IsCustomerVisible = 1
    ORDER BY h.SequenceNo;

    /* ---- 3: customer-visible comments ----------------------------------- */
    SELECT c.AuthorRole,
           /* The user's own name is shown back to them; support is shown as a
              team rather than as a named individual. */
           CASE WHEN c.AuthorRole = N'reporter' THEN c.AuthorUserName
                ELSE N'Support' END AS AuthorName,
           c.CommentText,
           c.CreatedUtc
    FROM ERM.ERM_TicketComment c
    WHERE c.ERM_TicketID = @ERM_TicketID
      AND c.IsCustomerVisible = 1
    ORDER BY c.CreatedUtc;
END
GO

/* =============================================================================
   usp_Ticket_AddUserComment
   -----------------------------------------------------------------------------
   The end user replying on their own ticket - what turns "Waiting for
   Information" into a conversation instead of a dead end.

   Returns the number of rows written: 1 on success, 0 if the ticket is not
   theirs or is closed.  The caller cannot distinguish those two, by design.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_AddUserComment
(
    @TicketNumber VARCHAR(30),
    @UserProfileID INT = NULL,
    @UserName     NVARCHAR(200) = NULL,
    @CommentText  NVARCHAR(MAX)
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @CommentText IS NULL OR LEN(LTRIM(RTRIM(@CommentText))) = 0
    BEGIN
        SELECT 0 AS RowsWritten;
        RETURN;
    END

    DECLARE @ERM_TicketID BIGINT =
        (SELECT ERM_TicketID AS TicketId FROM ERM.ERM_Ticket WHERE TicketNumber = @TicketNumber);

    IF @ERM_TicketID IS NULL OR ERM.fn_UserOwnsTicket(@ERM_TicketID, @UserProfileID) = 0
    BEGIN
        SELECT 0 AS RowsWritten;
        RETURN;
    END

    DECLARE @IsTerminal BIT =
        (SELECT st.IsTerminal FROM ERM.ERM_Ticket t
         JOIN ERM.ERM_TicketStatus st ON st.StatusID = t.StatusID
         WHERE t.ERM_TicketID = @ERM_TicketID);

    IF @IsTerminal = 1
    BEGIN
        SELECT 0 AS RowsWritten;
        RETURN;
    END

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRANSACTION;

        INSERT ERM.ERM_TicketComment
            (ERM_TicketID, AuthorUserProfileID, AuthorUserName, AuthorRole, CommentText,
             IsCustomerVisible, CreatedUtc, CreatedBy)
        VALUES
            (@ERM_TicketID, @UserProfileID, @UserName, N'reporter', @CommentText, 1, @Now,
             @UserProfileID);

        /* The assignee is the one waiting on this reply. Enqueued inside the
           transaction, so a rolled-back reply never announces itself. */
        IF OBJECT_ID(N'ERM.usp_Notification_Enqueue', N'P') IS NOT NULL
        BEGIN
            DECLARE @ReplyAssignee INT;
            SELECT @ReplyAssignee = t.AssignedToUserProfileID
            FROM ERM.ERM_Ticket t WHERE t.ERM_TicketID = @ERM_TicketID;

            EXEC ERM.usp_Notification_Enqueue
                 @RecipientUserProfileID = @ReplyAssignee,
                 @EventKind    = N'user_replied',
                 @ERM_TicketID = @ERM_TicketID,
                 @TicketNumber = @TicketNumber,
                 @Title        = N'A user has replied on a ticket assigned to you',
                 @Body         = @TicketNumber,
                 @ActedByUserProfileID = @UserProfileID;
        END

        /* A reply from the user un-blocks support.  Moving the ticket out of
           the paused status automatically is the difference between a queue
           that reflects reality and one support has to re-triage by hand -
           and it stops the user's reply sitting unread in a status that says
           "we are waiting for them".

           Done through usp_Ticket_ChangeStatus rather than an UPDATE so the
           transition is validated against the configured workflow and the
           audit row and paused-minutes accounting are written exactly as they
           are for a support-driven change.  If the configured workflow does
           not allow waiting_info -> in_progress, this is skipped rather than
           forced: the workflow is the authority, not this procedure. */
        DECLARE @StatusID TINYINT = (SELECT StatusID FROM ERM.ERM_Ticket WHERE ERM_TicketID = @ERM_TicketID);
        DECLARE @PausedNow BIT =
            (SELECT IsPaused FROM ERM.ERM_TicketStatus WHERE StatusID = @StatusID);

        IF @PausedNow = 1
        BEGIN
            DECLARE @InProgressId TINYINT =
                (SELECT StatusID FROM ERM.ERM_TicketStatus WHERE Code = N'in_progress' AND IsActive = 1);

            IF @InProgressId IS NOT NULL
               AND EXISTS (SELECT 1 FROM ERM.ERM_TicketStatusTransition
                           WHERE FromStatusID = @StatusID AND ToStatusID = @InProgressId AND IsActive = 1)
            BEGIN
                EXEC ERM.usp_Ticket_ChangeStatus
                     @ERM_TicketID          = @ERM_TicketID,
                     @ToStatusID        = @InProgressId,
                     @ChangedByUserProfileID = @UserProfileID,
                     @ChangedByUserName = @UserName,
                     @Comments          = N'Reporter replied with the requested information.',
                     @IsCustomerVisible = 1;
            END
        END

    COMMIT TRANSACTION;

    SELECT 1 AS RowsWritten;
END
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'007_end_user_ticket_access.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.1.0', ERM.fn_SystemUserID());
GO

GO

/* ==========================================================================
   SCRIPT: 010_search_performance.sql
   ========================================================================== */
GO
PRINT '--- 010_search_performance.sql ---';
GO

/* =============================================================================
   ERP Error Management Framework
   Script 010 - Server-side sorting, keyset paging, and the recurring-problems
                aggregate rewrite

   WHY THIS SCRIPT EXISTS
   ----------------------
   The v1.1 read procedures already did server-side FILTERING and PAGING, and
   the console never fetched a full result set to the browser. Three things were
   still wrong for a production-sized store, and a review question about
   pagination is exactly the right moment to fix them rather than explain them:

   1. SORTING WAS FIXED, NOT SELECTABLE.
      Every list had one hard-coded ORDER BY. A support console where you cannot
      sort by severity, module or occurrence count is a console people stop
      using. Now parameterised - safely; see the note on dynamic SQL below.

   2. usp_Error_RecurringProblems COUNTED PER ROW.
      It ran a correlated COUNT_BIG(*) plus a COUNT(DISTINCT UserName) over
      ErrorOccurrence once FOR EVERY fingerprint. With 4,000 fingerprints and
      40 million occurrences that is 4,000 separate index seeks, each with its
      own distinct-count sort. It worked fine on demo data and would have fallen
      over on real data - the worst kind of defect, because nothing reveals it
      until the table is big. Rewritten to aggregate the window ONCE.

   3. usp_Error_GetCorrelationTrail HAD NO LIMIT.
      During a cascading failure one correlation id can accumulate thousands of
      occurrences. An unbounded SELECT is how a diagnostic screen becomes the
      second outage.

   Plus one thing that is not a defect but a scale ceiling: OFFSET/FETCH has to
   walk and discard every row it skips. Page 3 is instant; page 20,000 of a
   40-million-row table is a scan. Keyset paging is added alongside it for the
   one list where that actually happens.

   Idempotent: yes. CREATE OR ALTER, so it supersedes the versions in 004.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =============================================================================
   Sort whitelist
   -----------------------------------------------------------------------------
   The ONLY safe way to do parameterised sorting without giving up index seeks.

   Two approaches were rejected:

   * `ORDER BY CASE @SortBy WHEN 'severity' THEN sv.RankOrder ... END`
     Safe, but the expression is not sargable, so SQL Server sorts the whole
     filtered set every time - it throws away the very index that makes the
     default view fast.

   * Concatenating @SortBy into dynamic SQL.
     Sargable, and a SQL-injection hole in the one schema that must never be
     injectable, since it holds every error message in the system.

   So: the caller's value is used ONLY as a LOOKUP KEY into this table. What
   reaches the ORDER BY clause is the OrderByClause column - text I wrote,
   never text the caller sent. An unrecognised key falls back to the default
   rather than erroring, because a support console should not 500 because
   somebody bookmarked a URL with a stale sort parameter.
   ============================================================================= */
IF OBJECT_ID(N'ERM.ERM_SortWhitelist', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_SortWhitelist
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_SortWhitelist_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_SortWhitelist_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_SortWhitelist_AppNo DEFAULT (1),
        /* 'error' | 'ticket' | 'problem' */
        ListName        NVARCHAR(20)    NOT NULL,
        SortKey         NVARCHAR(40)    NOT NULL,
        /* Literal ORDER BY text. Authored here, never caller-supplied. */
        OrderByClause   NVARCHAR(200)   NOT NULL,
        IsDefault       BIT             NOT NULL CONSTRAINT DF_SortWhitelist_IsDefault DEFAULT (0),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_SortWhitelist_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_SortWhitelist_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_SortWhitelist_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_SortWhitelist PRIMARY KEY CLUSTERED (ListName, SortKey)
    );
END
GO

/* Every clause ends with a unique tiebreaker. Without one, two rows with the
   same sort value can swap places between page 1 and page 2, so a row is shown
   twice and another is never shown at all - the classic "pagination loses
   records" bug, which looks like data loss to whoever reports it. */
MERGE ERM.ERM_SortWhitelist AS t
USING (VALUES
    /* ---- error occurrences ---- */
    (N'error',   N'occurred_desc',    N'o.OccurredUtc DESC, o.ERM_ErrorOccurrenceID DESC', 1),
    (N'error',   N'occurred_asc',     N'o.OccurredUtc ASC, o.ERM_ErrorOccurrenceID ASC', 0),
    (N'error',   N'severity',         N'sv.RankOrder ASC, o.OccurredUtc DESC, o.ERM_ErrorOccurrenceID DESC', 0),
    (N'error',   N'module',           N'o.ErpModule ASC, o.OccurredUtc DESC, o.ERM_ErrorOccurrenceID DESC', 0),
    (N'error',   N'screen',           N'o.Screen ASC, o.OccurredUtc DESC, o.ERM_ErrorOccurrenceID DESC', 0),
    (N'error',   N'user',             N'o.UserName ASC, o.UserProfileID ASC, o.OccurredUtc DESC, o.ERM_ErrorOccurrenceID DESC', 0),
    (N'error',   N'frequency',        N'f.OccurrenceCount DESC, o.OccurredUtc DESC, o.ERM_ErrorOccurrenceID DESC', 0),
    (N'error',   N'layer',            N'l.LayerID ASC, o.OccurredUtc DESC, o.ERM_ErrorOccurrenceID DESC', 0),

    /* ---- tickets ---- */
    (N'ticket',  N'severity',         N'sv.RankOrder ASC, t.CreatedUtc DESC, t.ERM_TicketID DESC', 1),
    (N'ticket',  N'created_desc',     N't.CreatedUtc DESC, t.ERM_TicketID DESC', 0),
    (N'ticket',  N'created_asc',      N't.CreatedUtc ASC, t.ERM_TicketID ASC', 0),
    (N'ticket',  N'status',           N'st.RankOrder ASC, t.CreatedUtc DESC, t.ERM_TicketID DESC', 0),
    (N'ticket',  N'queue',            N'q.Code ASC, t.CreatedUtc DESC, t.ERM_TicketID DESC', 0),
    (N'ticket',  N'assignee',         N't.AssignedToUserName ASC, t.CreatedUtc DESC, t.ERM_TicketID DESC', 0),
    (N'ticket',  N'linked',           N't.LinkedOccurrenceCount DESC, t.CreatedUtc DESC, t.ERM_TicketID DESC', 0),
    /* Oldest-open-first: the queue view that actually matters operationally. */
    (N'ticket',  N'age',              N'CASE WHEN st.IsOpen = 1 THEN 0 ELSE 1 END ASC, t.CreatedUtc ASC, t.ERM_TicketID ASC', 0),
    (N'ticket',  N'sla',              N'CASE WHEN t.SlaResolutionBreached = 1 OR t.SlaFirstResponseBreached = 1 THEN 0 ELSE 1 END ASC, sv.RankOrder ASC, t.CreatedUtc DESC, t.ERM_TicketID DESC', 0),

    /* ---- recurring problems ---- */
    (N'problem', N'window_count',     N'w.WindowOccurrences DESC, f.ERM_ErrorFingerprintID DESC', 1),
    (N'problem', N'lifetime_count',   N'f.OccurrenceCount DESC, f.ERM_ErrorFingerprintID DESC', 0),
    (N'problem', N'users',            N'w.WindowDistinctUsers DESC, f.ERM_ErrorFingerprintID DESC', 0),
    (N'problem', N'severity',         N'sv.RankOrder ASC, w.WindowOccurrences DESC, f.ERM_ErrorFingerprintID DESC', 0),
    (N'problem', N'last_seen',        N'f.LastSeenUtc DESC, f.ERM_ErrorFingerprintID DESC', 0),
    (N'problem', N'first_seen',       N'f.FirstSeenUtc ASC, f.ERM_ErrorFingerprintID ASC', 0),
    (N'problem', N'module',           N'f.ErpModule ASC, w.WindowOccurrences DESC, f.ERM_ErrorFingerprintID DESC', 0)
) AS s (ListName, SortKey, OrderByClause, IsDefault)
    ON t.ListName = s.ListName AND t.SortKey = s.SortKey
WHEN MATCHED THEN
    UPDATE SET OrderByClause = s.OrderByClause, IsDefault = s.IsDefault
WHEN NOT MATCHED THEN
    INSERT (ListName, SortKey, OrderByClause, IsDefault, CreatedBy)
    VALUES (s.ListName, s.SortKey, s.OrderByClause, s.IsDefault, ERM.fn_SystemUserID());
GO

CREATE OR ALTER FUNCTION ERM.fn_ResolveSort
(
    @ListName NVARCHAR(20),
    @SortKey  NVARCHAR(40),
    @Descending BIT = NULL      -- NULL = use the clause as written
)
RETURNS NVARCHAR(200)
AS
BEGIN
    DECLARE @clause NVARCHAR(200) =
        (SELECT OrderByClause FROM ERM.ERM_SortWhitelist
         WHERE ListName = @ListName AND SortKey = @SortKey);

    /* Unknown key -> the default for this list. Never an error: a stale
       bookmark must not break the console. */
    IF @clause IS NULL
        SET @clause = (SELECT TOP 1 OrderByClause FROM ERM.ERM_SortWhitelist
                       WHERE ListName = @ListName AND IsDefault = 1);

    RETURN @clause;
END
GO

/* =============================================================================
   usp_Error_Search  (supersedes 004)
   -----------------------------------------------------------------------------
   Server-side filtering, sorting and paging. Two paging modes:

   OFFSET/FETCH (default)  - supports "jump to page 47", needs a total count.
   KEYSET (@AfterOccurredUtc + @AfterOccurrenceId) - next/previous only, but
                             the cost does not grow with depth.

   @IncludeTotalCount defaults to 1 because a console needs "1-50 of 1,284",
   but on a very large filtered set that COUNT is the expensive half of the
   query. Turn it off for infinite-scroll views and it disappears.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Error_Search
(
    @ErrorReference VARCHAR(30)   = NULL,
    @TicketNumber   VARCHAR(30)   = NULL,
    @UserName       NVARCHAR(200) = NULL,
    @ErpModule      NVARCHAR(100) = NULL,
    @Screen         NVARCHAR(200) = NULL,
    @Component      NVARCHAR(200) = NULL,
    @ApiEndpoint    NVARCHAR(400) = NULL,
    @ExceptionType  NVARCHAR(400) = NULL,
    @SqlErrorNumber INT           = NULL,
    @CategoryCode   NVARCHAR(40)  = NULL,
    @SeverityCode   NVARCHAR(20)  = NULL,
    @LayerCode      NVARCHAR(30)  = NULL,
    @Environment    NVARCHAR(40)  = NULL,
    @CorrelationID  UNIQUEIDENTIFIER = NULL,
    @ERM_ErrorFingerprintID  BIGINT        = NULL,
    @FromUtc        DATETIME2(3)  = NULL,
    @ToUtc          DATETIME2(3)  = NULL,
    @SearchText     NVARCHAR(200) = NULL,
    @MinOccurrences INT           = NULL,
    @OnlyUnticketed BIT           = NULL,

    /* ---- sorting ---- */
    @SortBy         NVARCHAR(40)  = NULL,   -- key into ERM.ERM_SortWhitelist

    /* ---- paging ---- */
    @PageNumber     INT = 1,
    @PageSize       INT = 50,
    @IncludeTotalCount BIT = 1,
    /* Keyset cursor. Supply BOTH to page by seek instead of by offset. */
    @AfterOccurredUtc  DATETIME2(3) = NULL,
    @AfterOccurrenceId BIGINT       = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageSize IS NULL OR @PageSize < 1  SET @PageSize = 50;
    IF @PageSize > 500 SET @PageSize = 500;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;

    /* Default to the last 30 days rather than scanning history. An unbounded
       default is how a support console takes the ERP's SQL Server down. */
    IF @FromUtc IS NULL AND @ErrorReference IS NULL AND @TicketNumber IS NULL
       AND @CorrelationID IS NULL AND @ERM_ErrorFingerprintID IS NULL
        SET @FromUtc = DATEADD(DAY, -30, SYSUTCDATETIME());

    DECLARE @keyset BIT = CASE WHEN @AfterOccurredUtc IS NOT NULL AND @AfterOccurrenceId IS NOT NULL
                               THEN 1 ELSE 0 END;

    /* Keyset paging is only coherent for the default chronological order - the
       cursor IS (OccurredUtc, ERM_ErrorOccurrenceID). Asked for both, the sort wins and
       the cursor is ignored, because silently reordering the caller's results
       is worse than silently ignoring a cursor they can re-request. */
    IF @keyset = 1 AND @SortBy IS NOT NULL AND @SortBy <> N'occurred_desc'
        SET @keyset = 0;

    DECLARE @orderBy NVARCHAR(200) = ERM.fn_ResolveSort(N'error', @SortBy, NULL);

    DECLARE @sql NVARCHAR(MAX) = N'
    SELECT
        o.ERM_ErrorOccurrenceID AS OccurrenceId, o.ErrorReference, o.OccurredUtc, o.OccurredLocal,
        l.Code AS LayerCode, l.DisplayName AS LayerName,
        c.Code AS CategoryCode, c.DisplayName AS CategoryName,
        sv.Code AS SeverityCode, sv.DisplayName AS SeverityName, sv.RankOrder AS SeverityRank,
        o.ExceptionType, o.Message,
        o.ErpModule, o.Screen, o.Component, o.RouteUrl, o.ActionName, o.FormName, o.LovName,
        o.ApiApplication, o.ApiController, o.ApiAction, o.ApiEndpoint, o.HttpMethod, o.HttpStatusCode,
        o.SqlErrorNumber, o.SqlObjectName, o.SqlLineNumber,
        o.UserName, o.UserDisplayName, o.Environment, o.AppVersion,
        o.BrowserName, o.BrowserVersion, o.OsName,
        o.CorrelationID, o.RequestID,
        o.ERM_ErrorFingerprintID AS FingerprintId, f.FingerprintHash, f.OccurrenceCount AS FingerprintOccurrenceCount,
        f.DistinctUserCount, f.FirstSeenUtc, f.LastSeenUtc, f.TriageState,
        o.ERM_TicketID AS TicketId, tk.TicketNumber, ts.Code AS TicketStatusCode, ts.DisplayName AS TicketStatusName'
    + CASE WHEN @IncludeTotalCount = 1 THEN N',
        COUNT(*) OVER () AS TotalRowCount' ELSE N',
        CONVERT(BIGINT, NULL) AS TotalRowCount' END + N'
    FROM ERM.ERM_ErrorOccurrence o
    JOIN ERM.ERM_ErrorFingerprint f ON f.ERM_ErrorFingerprintID = o.ERM_ErrorFingerprintID
    JOIN ERM.ERM_AppLayer       l  ON l.LayerID    = o.LayerID
    JOIN ERM.ERM_ErrorCategory  c  ON c.CategoryID = o.CategoryID
    JOIN ERM.ERM_Severity       sv ON sv.SeverityID = o.SeverityID
    LEFT JOIN ERM.ERM_Ticket        tk ON tk.ERM_TicketID = o.ERM_TicketID
    LEFT JOIN ERM.ERM_TicketStatus  ts ON ts.StatusID = tk.StatusID
    WHERE (@ErrorReference IS NULL OR o.ErrorReference = @ErrorReference)
      AND (@TicketNumber   IS NULL OR tk.TicketNumber  = @TicketNumber)
      AND (@UserName       IS NULL OR o.UserName       = @UserName)
      AND (@ErpModule      IS NULL OR o.ErpModule      = @ErpModule)
      AND (@Screen         IS NULL OR o.Screen         = @Screen)
      AND (@Component      IS NULL OR o.Component      = @Component)
      AND (@ApiEndpoint    IS NULL OR o.ApiEndpoint LIKE @ApiEndpoint + N''%'')
      AND (@ExceptionType  IS NULL OR o.ExceptionType LIKE N''%'' + @ExceptionType + N''%'')
      AND (@SqlErrorNumber IS NULL OR o.SqlErrorNumber = @SqlErrorNumber)
      AND (@CategoryCode   IS NULL OR c.Code  = @CategoryCode)
      AND (@SeverityCode   IS NULL OR sv.Code = @SeverityCode)
      AND (@LayerCode      IS NULL OR l.Code  = @LayerCode)
      AND (@Environment    IS NULL OR o.Environment   = @Environment)
      AND (@CorrelationID  IS NULL OR o.CorrelationID = @CorrelationID)
      AND (@ERM_ErrorFingerprintID  IS NULL OR o.ERM_ErrorFingerprintID = @ERM_ErrorFingerprintID)
      AND (@FromUtc        IS NULL OR o.OccurredUtc  >= @FromUtc)
      AND (@ToUtc          IS NULL OR o.OccurredUtc  <= @ToUtc)
      AND (@MinOccurrences IS NULL OR f.OccurrenceCount >= @MinOccurrences)
      AND (@OnlyUnticketed IS NULL OR @OnlyUnticketed = 0 OR o.ERM_TicketID IS NULL)
      AND (@SearchText     IS NULL OR o.Message LIKE N''%'' + @SearchText + N''%''
                                   OR o.ExceptionType LIKE N''%'' + @SearchText + N''%''
                                   OR o.Screen LIKE N''%'' + @SearchText + N''%'')'
    + CASE WHEN @keyset = 1 THEN N'
      /* Keyset seek: the cost of this does not grow with page depth, unlike
         OFFSET, which has to walk and discard every row it skips. */
      AND (o.OccurredUtc < @AfterOccurredUtc
           OR (o.OccurredUtc = @AfterOccurredUtc AND o.ERM_ErrorOccurrenceID < @AfterOccurrenceId))'
      ELSE N'' END + N'
    ORDER BY ' + @orderBy
    + CASE WHEN @keyset = 1
           THEN N'
    OFFSET 0 ROWS FETCH NEXT @PageSize ROWS ONLY'
           ELSE N'
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY' END + N'
    OPTION (RECOMPILE);';

    /* RECOMPILE: the predicate combination varies wildly between calls and a
       cached plan for one shape is actively harmful for the next. This is a
       low-frequency admin query, so the compile cost is the right trade. */

    EXEC sp_executesql @sql,
        N'@ErrorReference VARCHAR(30), @TicketNumber VARCHAR(30), @UserName NVARCHAR(200),
          @ErpModule NVARCHAR(100), @Screen NVARCHAR(200), @Component NVARCHAR(200),
          @ApiEndpoint NVARCHAR(400), @ExceptionType NVARCHAR(400), @SqlErrorNumber INT,
          @CategoryCode NVARCHAR(40), @SeverityCode NVARCHAR(20), @LayerCode NVARCHAR(30),
          @Environment NVARCHAR(40), @CorrelationID UNIQUEIDENTIFIER, @ERM_ErrorFingerprintID BIGINT,
          @FromUtc DATETIME2(3), @ToUtc DATETIME2(3), @SearchText NVARCHAR(200),
          @MinOccurrences INT, @OnlyUnticketed BIT, @PageNumber INT, @PageSize INT,
          @AfterOccurredUtc DATETIME2(3), @AfterOccurrenceId BIGINT',
        @ErrorReference, @TicketNumber, @UserName, @ErpModule, @Screen, @Component,
        @ApiEndpoint, @ExceptionType, @SqlErrorNumber, @CategoryCode, @SeverityCode,
        @LayerCode, @Environment, @CorrelationID, @ERM_ErrorFingerprintID, @FromUtc, @ToUtc,
        @SearchText, @MinOccurrences, @OnlyUnticketed, @PageNumber, @PageSize,
        @AfterOccurredUtc, @AfterOccurrenceId;

    /* Note what is parameterised and what is concatenated: every VALUE is a
       parameter, and the only concatenated text is @orderBy, which came out of
       ERM.ERM_SortWhitelist. No caller-supplied string ever reaches the SQL
       text. */
END
GO

/* =============================================================================
   usp_Ticket_Search  (supersedes 004)
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_Search
(
    @TicketNumber   VARCHAR(30)   = NULL,
    @StatusCode     NVARCHAR(40)  = NULL,
    @OnlyOpen       BIT           = NULL,
    @QueueCode      NVARCHAR(40)  = NULL,
    @SeverityCode   NVARCHAR(20)  = NULL,
    @ReportedBy     NVARCHAR(200) = NULL,
    @AssignedTo     NVARCHAR(200) = NULL,
    @Unassigned     BIT           = NULL,
    @ErpModule      NVARCHAR(100) = NULL,
    @Environment    NVARCHAR(40)  = NULL,
    @BreachedSlaOnly BIT          = NULL,
    @CreatedVia     NVARCHAR(20)  = NULL,
    @FromUtc        DATETIME2(3)  = NULL,
    @ToUtc          DATETIME2(3)  = NULL,
    @SearchText     NVARCHAR(200) = NULL,
    @SortBy         NVARCHAR(40)  = NULL,
    @PageNumber     INT = 1,
    @PageSize       INT = 50,
    @IncludeTotalCount BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageSize IS NULL OR @PageSize < 1  SET @PageSize = 50;
    IF @PageSize > 500 SET @PageSize = 500;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;

    DECLARE @orderBy NVARCHAR(200) = ERM.fn_ResolveSort(N'ticket', @SortBy, NULL);

    DECLARE @sql NVARCHAR(MAX) = N'
    SELECT
        t.ERM_TicketID AS TicketId, t.TicketNumber, t.Title, t.CreatedVia,
        st.Code AS StatusCode, st.DisplayName AS StatusName, st.IsOpen, st.IsTerminal,
        sv.Code AS SeverityCode, sv.DisplayName AS SeverityName, sv.RankOrder AS SeverityRank,
        q.Code  AS QueueCode,  q.DisplayName AS QueueName,
        t.ReportedByUserName, t.AssignedToUserName, t.ErpModule, t.Environment,
        t.CreatedUtc, t.FirstResponseUtc, t.AssignedUtc, t.ResolvedUtc, t.ClosedUtc,
        CASE WHEN st.IsTerminal = 1 THEN t.TotalElapsedMinutes
             ELSE DATEDIFF(MINUTE, t.CreatedUtc, SYSUTCDATETIME()) END AS TotalElapsedMinutes,
        CASE WHEN st.IsTerminal = 1 THEN t.ActiveProcessingMinutes
             ELSE DATEDIFF(MINUTE, t.CreatedUtc, SYSUTCDATETIME())
                  - ISNULL((SELECT SUM(h.MinutesInFromStatus)
                            FROM ERM.ERM_TicketStatusHistory h
                            JOIN ERM.ERM_TicketStatus s2 ON s2.StatusID = h.FromStatusID
                            WHERE h.ERM_TicketID = t.ERM_TicketID AND s2.IsPaused = 1), 0)
                  - CASE WHEN st.IsPaused = 1
                         THEN DATEDIFF(MINUTE, t.LastStatusChangeUtc, SYSUTCDATETIME())
                         ELSE 0 END
        END AS ActiveProcessingMinutes,
        t.SlaFirstResponseBreached, t.SlaResolutionBreached,
        p.FirstResponseMinutes AS SlaFirstResponseTargetMinutes,
        p.ResolutionMinutes    AS SlaResolutionTargetMinutes,
        t.ReopenCount, t.LinkedOccurrenceCount,
        t.ERM_ErrorFingerprintID AS FingerprintId, o.ErrorReference AS PrimaryErrorReference'
    + CASE WHEN @IncludeTotalCount = 1 THEN N',
        COUNT(*) OVER () AS TotalRowCount' ELSE N',
        CONVERT(BIGINT, NULL) AS TotalRowCount' END + N'
    FROM ERM.ERM_Ticket t
    JOIN ERM.ERM_TicketStatus st ON st.StatusID = t.StatusID
    JOIN ERM.ERM_Severity     sv ON sv.SeverityID = t.SeverityID
    JOIN ERM.ERM_TicketQueue  q  ON q.ERM_TicketQueueID     = t.ERM_TicketQueueID
    LEFT JOIN ERM.ERM_SlaPolicy p ON p.ERM_SlaPolicyID = t.ERM_SlaPolicyID
    LEFT JOIN ERM.ERM_ErrorOccurrence o ON o.ERM_ErrorOccurrenceID = t.ERM_ErrorOccurrenceID
    WHERE (@TicketNumber IS NULL OR t.TicketNumber = @TicketNumber)
      AND (@StatusCode   IS NULL OR st.Code = @StatusCode)
      AND (@OnlyOpen     IS NULL OR st.IsOpen = @OnlyOpen)
      AND (@QueueCode    IS NULL OR q.Code  = @QueueCode)
      AND (@SeverityCode IS NULL OR sv.Code = @SeverityCode)
      AND (@ReportedBy   IS NULL OR t.ReportedByUserName = @ReportedBy)
      AND (@AssignedTo   IS NULL OR t.AssignedToUserName = @AssignedTo)
      AND (@Unassigned   IS NULL OR @Unassigned = 0 OR t.AssignedToUserName IS NULL)
      AND (@ErpModule    IS NULL OR t.ErpModule   = @ErpModule)
      AND (@Environment  IS NULL OR t.Environment = @Environment)
      AND (@CreatedVia   IS NULL OR t.CreatedVia  = @CreatedVia)
      AND (@BreachedSlaOnly IS NULL OR @BreachedSlaOnly = 0
           OR t.SlaFirstResponseBreached = 1 OR t.SlaResolutionBreached = 1)
      AND (@FromUtc IS NULL OR t.CreatedUtc >= @FromUtc)
      AND (@ToUtc   IS NULL OR t.CreatedUtc <= @ToUtc)
      AND (@SearchText IS NULL OR t.Title LIKE N''%'' + @SearchText + N''%''
                               OR t.TicketNumber LIKE N''%'' + @SearchText + N''%''
                               OR t.UserDescription LIKE N''%'' + @SearchText + N''%'')
    ORDER BY ' + @orderBy + N'
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);';

    EXEC sp_executesql @sql,
        N'@TicketNumber VARCHAR(30), @StatusCode NVARCHAR(40), @OnlyOpen BIT,
          @QueueCode NVARCHAR(40), @SeverityCode NVARCHAR(20), @ReportedBy NVARCHAR(200),
          @AssignedTo NVARCHAR(200), @Unassigned BIT, @ErpModule NVARCHAR(100),
          @Environment NVARCHAR(40), @CreatedVia NVARCHAR(20), @BreachedSlaOnly BIT,
          @FromUtc DATETIME2(3), @ToUtc DATETIME2(3), @SearchText NVARCHAR(200),
          @PageNumber INT, @PageSize INT',
        @TicketNumber, @StatusCode, @OnlyOpen, @QueueCode, @SeverityCode, @ReportedBy,
        @AssignedTo, @Unassigned, @ErpModule, @Environment, @CreatedVia, @BreachedSlaOnly,
        @FromUtc, @ToUtc, @SearchText, @PageNumber, @PageSize;
END
GO

/* =============================================================================
   usp_Error_RecurringProblems  (supersedes 004 - THE IMPORTANT REWRITE)
   -----------------------------------------------------------------------------
   The old version:

       SELECT TOP (@TopN) f.*, w.WindowOccurrences
       FROM ERM.ERM_ErrorFingerprint f
       CROSS APPLY (SELECT COUNT_BIG(*), COUNT(DISTINCT o.UserName)
                    FROM ERM.ERM_ErrorOccurrence o
                    WHERE o.ERM_ErrorFingerprintID = f.ERM_ErrorFingerprintID
                      AND o.OccurredUtc >= @FromUtc) w
       WHERE w.WindowOccurrences >= @MinOccurrences

   That CROSS APPLY executes ONCE PER FINGERPRINT. Every fingerprint in the
   table - including the thousands that had no occurrence in the window at all -
   gets its own index seek plus a distinct-count. It is O(fingerprints), and the
   filter that would have eliminated most of them is applied AFTER the count.

   The rewrite aggregates the occurrence table ONCE, over the window only, and
   joins the result. It touches the occurrences in the window and nothing else,
   so the cost tracks the size of the WINDOW rather than the size of the TABLE.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Error_RecurringProblems
(
    @FromUtc        DATETIME2(3) = NULL,
    @ToUtc          DATETIME2(3) = NULL,
    @MinOccurrences INT = 5,
    @SeverityCode   NVARCHAR(20)  = NULL,
    @LayerCode      NVARCHAR(30)  = NULL,
    @ErpModule      NVARCHAR(100) = NULL,
    @TriageState    NVARCHAR(20)  = NULL,
    @IncludeMuted   BIT = 0,
    @SortBy         NVARCHAR(40)  = NULL,
    @PageNumber     INT = 1,
    @PageSize       INT = 50,
    @IncludeTotalCount BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @FromUtc IS NULL SET @FromUtc = DATEADD(DAY, -7, SYSUTCDATETIME());
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 50;
    IF @PageSize > 500 SET @PageSize = 500;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @MinOccurrences IS NULL OR @MinOccurrences < 1 SET @MinOccurrences = 1;

    DECLARE @orderBy NVARCHAR(200) = ERM.fn_ResolveSort(N'problem', @SortBy, NULL);

    /* ONE pass over the window, grouped. Materialised into a temp table rather
       than left as a CTE so the optimiser gets real cardinality for the join
       below - with a CTE it repeatedly guessed low here and chose a nested loop
       over what is actually a large aggregate. */
    CREATE TABLE #win
    (
        ERM_ErrorFingerprintID       BIGINT      NOT NULL PRIMARY KEY,
        WindowOccurrences   BIGINT      NOT NULL,
        WindowDistinctUsers INT         NOT NULL,
        WindowLastSeenUtc   DATETIME2(3) NULL
    );

    INSERT #win (ERM_ErrorFingerprintID, WindowOccurrences, WindowDistinctUsers, WindowLastSeenUtc)
    SELECT o.ERM_ErrorFingerprintID,
           COUNT_BIG(*),
           COUNT(DISTINCT o.UserName),
           MAX(o.OccurredUtc)
    FROM ERM.ERM_ErrorOccurrence o
    WHERE o.OccurredUtc >= @FromUtc
      AND (@ToUtc IS NULL OR o.OccurredUtc <= @ToUtc)
    GROUP BY o.ERM_ErrorFingerprintID
    /* Applied HERE, during aggregation, so the join below only ever sees rows
       that already qualify. */
    HAVING COUNT_BIG(*) >= @MinOccurrences;

    DECLARE @sql NVARCHAR(MAX) = N'
    SELECT
        f.ERM_ErrorFingerprintID AS FingerprintId, f.FingerprintHash, f.SignatureText,
        sv.Code AS SeverityCode, sv.DisplayName AS SeverityName,
        c.Code  AS CategoryCode, c.DisplayName AS CategoryName,
        l.Code  AS LayerCode,
        f.ExceptionType, f.NormalizedMessage,
        f.ErpModule, f.Screen, f.Component, f.ApiEndpoint, f.SqlObjectName,
        f.FirstSeenUtc, f.LastSeenUtc, f.TriageState, f.MutedUntilUtc,
        f.OccurrenceCount AS LifetimeOccurrences,
        f.DistinctUserCount AS LifetimeDistinctUsers,
        w.WindowOccurrences, w.WindowDistinctUsers, w.WindowLastSeenUtc,
        f.OpenTicketID, tk.TicketNumber AS OpenTicketNumber,
        tks.Code AS OpenTicketStatusCode'
    + CASE WHEN @IncludeTotalCount = 1 THEN N',
        COUNT(*) OVER () AS TotalRowCount' ELSE N',
        CONVERT(BIGINT, NULL) AS TotalRowCount' END + N'
    FROM #win w
    JOIN ERM.ERM_ErrorFingerprint f ON f.ERM_ErrorFingerprintID = w.ERM_ErrorFingerprintID
    JOIN ERM.ERM_Severity      sv ON sv.SeverityID = f.SeverityID
    JOIN ERM.ERM_ErrorCategory c  ON c.CategoryID  = f.CategoryID
    JOIN ERM.ERM_AppLayer      l  ON l.LayerID     = f.LayerID
    LEFT JOIN ERM.ERM_Ticket       tk  ON tk.ERM_TicketID  = f.OpenTicketID
    LEFT JOIN ERM.ERM_TicketStatus tks ON tks.StatusID = tk.StatusID
    WHERE (@SeverityCode IS NULL OR sv.Code = @SeverityCode)
      AND (@LayerCode    IS NULL OR l.Code  = @LayerCode)
      AND (@ErpModule    IS NULL OR f.ErpModule = @ErpModule)
      AND (@TriageState  IS NULL OR f.TriageState = @TriageState)
      AND (@IncludeMuted = 1 OR (f.TriageState <> N''muted''
           AND (f.MutedUntilUtc IS NULL OR f.MutedUntilUtc <= SYSUTCDATETIME())))
    ORDER BY ' + @orderBy + N'
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;';

    EXEC sp_executesql @sql,
        N'@SeverityCode NVARCHAR(20), @LayerCode NVARCHAR(30), @ErpModule NVARCHAR(100),
          @TriageState NVARCHAR(20), @IncludeMuted BIT, @PageNumber INT, @PageSize INT',
        @SeverityCode, @LayerCode, @ErpModule, @TriageState, @IncludeMuted,
        @PageNumber, @PageSize;

    DROP TABLE #win;
END
GO

/* =============================================================================
   usp_Error_GetCorrelationTrail  (supersedes 004 - now bounded)
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Error_GetCorrelationTrail
(
    @CorrelationID UNIQUEIDENTIFIER,
    /* A cascading failure can put thousands of occurrences under one
       correlation id. The trail is a diagnostic read, so it is capped - an
       unbounded SELECT here is how a diagnostic screen becomes the second
       outage. */
    @MaxRows INT = 200
)
AS
BEGIN
    SET NOCOUNT ON;
    IF @MaxRows IS NULL OR @MaxRows < 1 SET @MaxRows = 200;
    IF @MaxRows > 1000 SET @MaxRows = 1000;

    /* Total first, so the UI can say "showing 200 of 3,412" rather than
       quietly truncating - a truncated trail that looks complete is how you
       conclude the cause was not captured. */
    SELECT COUNT_BIG(*) AS TotalInTrail
    FROM ERM.ERM_ErrorOccurrence
    WHERE CorrelationID = @CorrelationID;

    SELECT TOP (@MaxRows)
           o.ERM_ErrorOccurrenceID AS OccurrenceId, o.ErrorReference, o.OccurredUtc, o.ReceivedUtc,
           l.Code AS LayerCode, l.DisplayName AS LayerName, l.LayerID,
           c.Code AS CategoryCode, sv.Code AS SeverityCode,
           o.ExceptionType, o.Message,
           o.Component, o.Screen, o.ApiController, o.ApiAction, o.HttpStatusCode,
           o.SqlErrorNumber, o.SqlObjectName, o.SqlLineNumber,
           o.ParentOccurrenceID, o.RequestID, o.UserName,
           d.StackTrace, d.InnerExceptionChain, d.SqlStatementText
    FROM ERM.ERM_ErrorOccurrence o
    JOIN ERM.ERM_AppLayer      l  ON l.LayerID     = o.LayerID
    JOIN ERM.ERM_ErrorCategory c  ON c.CategoryID  = o.CategoryID
    JOIN ERM.ERM_Severity      sv ON sv.SeverityID = o.SeverityID
    LEFT JOIN ERM.ERM_ErrorOccurrenceDetail d ON d.ERM_ErrorOccurrenceID = o.ERM_ErrorOccurrenceID
    WHERE o.CorrelationID = @CorrelationID
    /* Deepest layer first: the cause, then the symptom. */
    ORDER BY l.LayerID DESC, o.OccurredUtc ASC, o.ERM_ErrorOccurrenceID ASC;
END
GO

/* =============================================================================
   Supporting indexes
   -----------------------------------------------------------------------------
   The whitelist above offers sorts that 002's indexes do not cover. Sorting by
   a column with no supporting index means SQL Server sorts the entire filtered
   set on every page request, which is exactly the "works in the demo, crawls in
   production" failure this script exists to avoid.

   Created WITH (ONLINE = ON) where the edition allows it, and each is checked
   for existence first, so this is safe to run against a live database.
   ============================================================================= */

/* The single most-used query shape: recent errors for one module. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Occurrence_Module_Occurred'
               AND object_id = OBJECT_ID(N'ERM.ERM_ErrorOccurrence'))
    CREATE INDEX IX_Occurrence_Module_Occurred
        ON ERM.ERM_ErrorOccurrence (ErpModule, OccurredUtc DESC)
        INCLUDE (SeverityID, LayerID, ErrorReference, UserName, ERM_TicketID, ERM_ErrorFingerprintID);
GO

/* Sort by severity within a window. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Occurrence_Severity_Occurred'
               AND object_id = OBJECT_ID(N'ERM.ERM_ErrorOccurrence'))
    CREATE INDEX IX_Occurrence_Severity_Occurred
        ON ERM.ERM_ErrorOccurrence (SeverityID, OccurredUtc DESC)
        INCLUDE (ErpModule, Screen, UserName, ErrorReference, ERM_ErrorFingerprintID, ERM_TicketID);
GO

/* The recurring-problems aggregate: grouped by fingerprint over a date window.
   Leading on OccurredUtc because the window is the selective predicate, and
   ERM_ErrorFingerprintID + UserName included so the GROUP BY and the DISTINCT count are
   both covered - no lookup to the base table at all. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Occurrence_Window_Aggregate'
               AND object_id = OBJECT_ID(N'ERM.ERM_ErrorOccurrence'))
    CREATE INDEX IX_Occurrence_Window_Aggregate
        ON ERM.ERM_ErrorOccurrence (OccurredUtc)
        INCLUDE (ERM_ErrorFingerprintID, UserName);
GO

/* "Errors with no ticket yet" - the triage inbox. Filtered, so it costs
   almost nothing to maintain and stays small. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Occurrence_Unticketed'
               AND object_id = OBJECT_ID(N'ERM.ERM_ErrorOccurrence'))
    CREATE INDEX IX_Occurrence_Unticketed
        ON ERM.ERM_ErrorOccurrence (OccurredUtc DESC)
        INCLUDE (ErrorReference, SeverityID, ErpModule, Screen, UserName, ERM_ErrorFingerprintID)
        WHERE ERM_TicketID IS NULL;
GO

/* Ticket queue sorts: oldest-open-first and SLA-breach-first. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Ticket_Open_Created'
               AND object_id = OBJECT_ID(N'ERM.ERM_Ticket'))
    CREATE INDEX IX_Ticket_Open_Created
        ON ERM.ERM_Ticket (StatusID, CreatedUtc)
        INCLUDE (TicketNumber, SeverityID, ERM_TicketQueueID, AssignedToUserName,
                 SlaFirstResponseBreached, SlaResolutionBreached, LinkedOccurrenceCount);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Ticket_Unassigned'
               AND object_id = OBJECT_ID(N'ERM.ERM_Ticket'))
    CREATE INDEX IX_Ticket_Unassigned
        ON ERM.ERM_Ticket (CreatedUtc DESC)
        INCLUDE (TicketNumber, StatusID, SeverityID, ERM_TicketQueueID)
        WHERE AssignedToUserName IS NULL;
GO

/* The end-user "My Tickets" list, which is the only one of these an ordinary
   user can trigger - so it is the one that must never be slow. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Ticket_Reporter_Created'
               AND object_id = OBJECT_ID(N'ERM.ERM_Ticket'))
    CREATE INDEX IX_Ticket_Reporter_Created
        ON ERM.ERM_Ticket (ReportedByUserName, CreatedUtc DESC)
        INCLUDE (TicketNumber, Title, StatusID, SeverityID, ErpModule,
                 ResolvedUtc, ClosedUtc);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Ticket_ReporterId_Created'
               AND object_id = OBJECT_ID(N'ERM.ERM_Ticket'))
    CREATE INDEX IX_Ticket_ReporterId_Created
        ON ERM.ERM_Ticket (ReportedByUserID, CreatedUtc DESC)
        INCLUDE (TicketNumber, Title, StatusID, SeverityID, ErpModule,
                 ResolvedUtc, ClosedUtc);
GO

/* -----------------------------------------------------------------------------
   OPTIONAL, and worth considering once the store is large: a columnstore index
   on the occurrence table makes the dashboard aggregates and the
   recurring-problems GROUP BY dramatically faster, at the cost of slower
   single-row lookups.

   NOT created here. It needs a maintenance window, it changes the plan for
   every query in this script, and on a table that is being written to
   constantly it wants to be tested on your data first. Offered, not assumed:

       CREATE NONCLUSTERED COLUMNSTORE INDEX NCCX_Occurrence
           ON ERM.ERM_ErrorOccurrence
              (OccurredUtc, ERM_ErrorFingerprintID, LayerID, CategoryID, SeverityID,
               ErpModule, Screen, UserName, Environment)
           WITH (MAXDOP = 2);
   ----------------------------------------------------------------------------- */

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'010_search_performance.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.2.0', ERM.fn_SystemUserID());
GO

GO

/* ==========================================================================
   SCRIPT: 011_support_access_and_manual_tickets.sql
   ========================================================================== */
GO
PRINT '--- 011_support_access_and_manual_tickets.sql ---';
GO

/* =============================================================================
   ERP Error Management Framework
   Script 011 - Support roster and roles, assignment as a first-class audited
                operation, and manually raised tickets

   WHAT THIS ADDS, AND WHY EACH ONE WAS MISSING
   --------------------------------------------
   1. A SUPPORT ROSTER AND ROLES.
      Until now there was nothing in the schema that said who support staff
      are. The end-user path was safe (ownership is enforced in SQL), but the
      admin path had no authorisation model at all, and "restrict the console"
      cannot be answered by a UI route guard - a route guard hides a screen, it
      does not protect an endpoint.

   2. ASSIGNMENT WAS NOT PROPERLY AUDITED.
      usp_Ticket_ChangeStatus accepted @AssignToUserName and wrote it to the
      Ticket row, and the transition INTO Assigned appeared in the history with
      who made the change. But the history row never recorded WHO THE TICKET
      WAS ASSIGNED TO, so "who was it assigned to on Tuesday, and who moved it"
      was unanswerable - you could only see the current assignee. Reassignment
      between two support users left no trace whatsoever, because it is not a
      status change.

   3. A TICKET COULD NOT EXIST WITHOUT AN ERROR.
      Ticket.ERM_ErrorFingerprintID was NOT NULL, so every ticket had to hang off a
      captured occurrence. A user who wants to report "the totals on this report
      look wrong" has no error to attach - nothing threw. That is a normal
      support request and the schema could not represent it.

   Idempotent: yes. Safe on a live database - the ALTERs are additive and the
   NOT NULL relaxation cannot fail on existing rows.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =============================================================================
   PART 1 - Support roster and roles
   ============================================================================= */

IF OBJECT_ID(N'ERM.ERM_SupportRole', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_SupportRole
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_SupportRole_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_SupportRole_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_SupportRole_AppNo DEFAULT (1),
        RoleID          TINYINT         NOT NULL,
        Code            NVARCHAR(40)    NOT NULL,
        DisplayName     NVARCHAR(100)   NOT NULL,
        /* Capability flags rather than a hierarchy. A hierarchy forces you to
           decide whether "can triage" outranks "can configure", which is a
           question with no correct answer - real support teams have people who
           do one and not the other. */
        CanViewErrors       BIT NOT NULL CONSTRAINT DF_SupportRole_View    DEFAULT (1),
        CanViewDiagnostics  BIT NOT NULL CONSTRAINT DF_SupportRole_Diag    DEFAULT (1),
        CanManageTickets    BIT NOT NULL CONSTRAINT DF_SupportRole_Manage  DEFAULT (1),
        CanBeAssigned       BIT NOT NULL CONSTRAINT DF_SupportRole_Assign  DEFAULT (1),
        CanTriage           BIT NOT NULL CONSTRAINT DF_SupportRole_Triage  DEFAULT (0),
        CanConfigure        BIT NOT NULL CONSTRAINT DF_SupportRole_Config  DEFAULT (0),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_SupportRole_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_SupportRole_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_SupportRole_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_SupportRole PRIMARY KEY CLUSTERED (RoleID),
        CONSTRAINT UQ_SupportRole_Code UNIQUE (Code)
    );
END
GO

MERGE ERM.ERM_SupportRole AS t
USING (VALUES
    /*                              view  diag  manage  assignable  triage  config */
    (1, N'support_agent',  N'Support Agent',      1,    1,    1,      1,          0,      0),
    (2, N'support_lead',   N'Support Lead',       1,    1,    1,      1,          1,      0),
    (3, N'developer',      N'Developer',          1,    1,    1,      1,          1,      0),
    /* Read-only: for a manager who needs the dashboard and the recurring-problem
       report but has no business changing ticket state. */
    (4, N'support_viewer', N'Support Viewer',     1,    0,    0,      0,          0,      0),
    (5, N'administrator',  N'Administrator',      1,    1,    1,      1,          1,      1)
) AS s (RoleID, Code, DisplayName, CanViewErrors, CanViewDiagnostics,
        CanManageTickets, CanBeAssigned, CanTriage, CanConfigure)
    ON t.RoleID = s.RoleID
WHEN NOT MATCHED THEN
    INSERT (RoleID, Code, DisplayName, CanViewErrors, CanViewDiagnostics,
            CanManageTickets, CanBeAssigned, CanTriage, CanConfigure, CreatedBy)
    VALUES (s.RoleID, s.Code, s.DisplayName, s.CanViewErrors, s.CanViewDiagnostics,
            s.CanManageTickets, s.CanBeAssigned, s.CanTriage, s.CanConfigure,
            ERM.fn_SystemUserID());
GO

/* -----------------------------------------------------------------------------
   The roster.

   This is deliberately NOT a copy of your user directory. It holds only the
   people who have a support function, keyed by their ERP UserProfileID, so the
   framework never needs to read your ERP's user tables - which is the same
   isolation rule as everything else in ERM.

   It serves two purposes that are easy to conflate:
     * AUTHORISATION  - may this caller use the admin API at all?
     * ASSIGNABILITY  - who may appear in the "assign to" picker?
   They are different: a departed agent stays in the roster (so their name still
   resolves in old audit rows) with IsActive = 0, which removes them from the
   picker AND from access.
   ----------------------------------------------------------------------------- */
IF OBJECT_ID(N'ERM.ERM_SupportUser', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_SupportUser
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_SupportUser_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_SupportUser_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_SupportUser_AppNo DEFAULT (1),
        ERM_SupportUserID   INT             IDENTITY(1,1) NOT NULL,
        /* The ERP's own UserProfileID, and nothing else. An earlier draft
           matched on a token id OR a user name, to survive an auth migration.
           That is the wrong trade here: ATC has one canonical user key, and
           two ways to identify the same person is two ways for authorisation
           to disagree with itself. UserName below is display text only. */
        UserProfileID   INT             NOT NULL,
        UserName        NVARCHAR(200)   NULL,
        DisplayName     NVARCHAR(200)   NOT NULL,
        RoleID          TINYINT         NOT NULL,
        /* NULL = may be assigned work from any queue. */
        DefaultQueueID  SMALLINT        NULL,
        /* Out of office: excluded from the picker, access unaffected. */
        IsAvailable     BIT             NOT NULL CONSTRAINT DF_SupportUser_Available DEFAULT (1),
        CreatedUtc      DATETIME2(3)    NOT NULL CONSTRAINT DF_SupportUser_Created DEFAULT (SYSUTCDATETIME()),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_SupportUser_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_SupportUser_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_SupportUser_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_SupportUser PRIMARY KEY CLUSTERED (ERM_SupportUserID),
        CONSTRAINT FK_SupportUser_Role  FOREIGN KEY (RoleID)         REFERENCES ERM.ERM_SupportRole (RoleID),
        CONSTRAINT FK_SupportUser_Queue FOREIGN KEY (DefaultQueueID) REFERENCES ERM.ERM_TicketQueue (ERM_TicketQueueID),
        /* -1 is the non-user value; it must never be able to hold support
           rights, or every anonymous caller would be an administrator. */
        CONSTRAINT CK_SupportUser_RealUser CHECK (UserProfileID > 0)
    );

    /* One roster row per person. */
    CREATE UNIQUE INDEX UX_SupportUser_UserProfileID
        ON ERM.ERM_SupportUser (UserProfileID);
END
GO

/* -----------------------------------------------------------------------------
   The authorisation predicate, in one place.

   Everything the admin API does goes through this. Having it in SQL as well as
   in the API is deliberate: the API check is what returns a clean 403, and this
   is what makes a forgotten check fail closed rather than silently allowing.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION ERM.fn_SupportCapability
(
    @UserProfileID INT,
    /* 'view' | 'diagnostics' | 'manage' | 'triage' | 'configure' */
    @Capability NVARCHAR(20)
)
RETURNS BIT
AS
BEGIN
    /* No identity = no capability. NULL is an anonymous caller and -1 is the
       framework's own non-user value; neither may ever satisfy this, whatever
       else is true. This is the line that makes a forgotten check fail
       closed. */
    IF @UserProfileID IS NULL OR @UserProfileID <= 0 RETURN 0;

    DECLARE @granted BIT = 0;

    SELECT @granted = CASE @Capability
                        WHEN N'view'        THEN r.CanViewErrors
                        WHEN N'diagnostics' THEN r.CanViewDiagnostics
                        WHEN N'manage'      THEN r.CanManageTickets
                        WHEN N'triage'      THEN r.CanTriage
                        WHEN N'configure'   THEN r.CanConfigure
                        ELSE CONVERT(BIT, 0)
                      END
    FROM ERM.ERM_SupportUser su
    JOIN ERM.ERM_SupportRole r ON r.RoleID = su.RoleID
    WHERE su.IsActive = 1
      AND r.IsActive = 1
      AND su.UserProfileID = @UserProfileID;

    RETURN ISNULL(@granted, 0);
END
GO

/* Who the caller is, and what they may do - one round trip for the API to
   cache per request. */
CREATE OR ALTER PROCEDURE ERM.usp_Support_WhoAmI
(
    @UserProfileID INT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @UserProfileID IS NULL OR @UserProfileID <= 0 RETURN;

    SELECT TOP 1
           su.ERM_SupportUserID, su.DisplayName, su.UserProfileID, su.UserName,
           r.Code AS RoleCode, r.DisplayName AS RoleName,
           r.CanViewErrors, r.CanViewDiagnostics, r.CanManageTickets,
           r.CanBeAssigned, r.CanTriage, r.CanConfigure,
           su.DefaultQueueID, q.Code AS DefaultQueueCode,
           su.IsAvailable
    FROM ERM.ERM_SupportUser su
    JOIN ERM.ERM_SupportRole r ON r.RoleID = su.RoleID
    LEFT JOIN ERM.ERM_TicketQueue q ON q.ERM_TicketQueueID = su.DefaultQueueID
    WHERE su.IsActive = 1 AND r.IsActive = 1
      AND su.UserProfileID = @UserProfileID;

    /* No row = not support staff. The API turns that into a 403; the absence
       of a row is the answer, not an error. */
END
GO

/* The "assign to" picker. Only people who may actually be assigned work. */
CREATE OR ALTER PROCEDURE ERM.usp_SupportUser_ListAssignable
(
    @ERM_TicketQueueID SMALLINT = NULL,
    @IncludeUnavailable BIT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT su.ERM_SupportUserID, su.UserProfileID, su.UserName, su.DisplayName,
           r.Code AS RoleCode, r.DisplayName AS RoleName,
           su.DefaultQueueID, q.Code AS DefaultQueueCode,
           su.IsAvailable,
           /* Current workload, so a lead can see who is already buried rather
              than assigning by alphabetical order. */
           (SELECT COUNT_BIG(*) FROM ERM.ERM_Ticket t
            JOIN ERM.ERM_TicketStatus ts ON ts.StatusID = t.StatusID
            WHERE ts.IsOpen = 1
              AND t.AssignedToUserProfileID = su.UserProfileID
           ) AS OpenTicketCount
    FROM ERM.ERM_SupportUser su
    JOIN ERM.ERM_SupportRole r ON r.RoleID = su.RoleID
    LEFT JOIN ERM.ERM_TicketQueue q ON q.ERM_TicketQueueID = su.DefaultQueueID
    WHERE su.IsActive = 1
      AND r.IsActive = 1
      AND r.CanBeAssigned = 1
      AND (@IncludeUnavailable = 1 OR su.IsAvailable = 1)
      /* A user with no default queue can take work from any queue. */
      AND (@ERM_TicketQueueID IS NULL OR su.DefaultQueueID IS NULL OR su.DefaultQueueID = @ERM_TicketQueueID)
    ORDER BY su.IsAvailable DESC, OpenTicketCount ASC, su.DisplayName ASC;
END
GO

/* =============================================================================
   PART 2 - Assignment as a first-class, audited operation
   ============================================================================= */

/* The history row now records the assignee, and the previous assignee.

   Without these, a reassignment between two support users - which is not a
   status change and so never triggered a history row at all - left no trace,
   and even the initial assignment only recorded who PERFORMED it, never who
   RECEIVED it. */
IF COL_LENGTH(N'ERM.ERM_TicketStatusHistory', N'AssignedToUserProfileID') IS NULL
    ALTER TABLE ERM.ERM_TicketStatusHistory ADD AssignedToUserProfileID INT NULL;
GO
IF COL_LENGTH(N'ERM.ERM_TicketStatusHistory', N'AssignedToUserName') IS NULL
    ALTER TABLE ERM.ERM_TicketStatusHistory ADD AssignedToUserName NVARCHAR(200) NULL;
GO
IF COL_LENGTH(N'ERM.ERM_TicketStatusHistory', N'PreviousAssignedToUserName') IS NULL
    ALTER TABLE ERM.ERM_TicketStatusHistory ADD PreviousAssignedToUserName NVARCHAR(200) NULL;
GO
/* 'status' | 'assignment' | 'both' - so a reassignment is a real audit row
   rather than a status change that happens to differ. */
IF COL_LENGTH(N'ERM.ERM_TicketStatusHistory', N'ChangeKind') IS NULL
    ALTER TABLE ERM.ERM_TicketStatusHistory
        ADD ChangeKind NVARCHAR(20) NOT NULL
            CONSTRAINT DF_TSH_ChangeKind DEFAULT (N'status');
GO

/* -----------------------------------------------------------------------------
   usp_Ticket_Assign
   -----------------------------------------------------------------------------
   Assignment WITHOUT requiring a status change, and validated against the
   roster - so a ticket cannot be assigned to somebody who does not exist, has
   left, or holds a role that is not assignable. A free-text assignee field
   looks harmless right up to the first typo, after which the ticket is
   assigned to nobody and appears in no queue.

   Writes a history row every time, including for reassignment.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_Assign
(
    @TicketNumber       VARCHAR(30),
    /* NULL = unassign. */
    @AssignToUserProfileID  INT = NULL,
    @ChangedByUserProfileID INT = NULL,
    @ChangedByUserName  NVARCHAR(200) = NULL,
    @Comments           NVARCHAR(MAX) = NULL,
    /* Move New -> Assigned at the same time, if the workflow permits it. */
    @AdvanceStatus      BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* The caller must be allowed to manage tickets. Checked here as well as in
       the API so that a forgotten check fails closed. */
    IF ERM.fn_SupportCapability(@ChangedByUserProfileID, N'manage') = 0
    BEGIN
        RAISERROR (N'Not authorised to manage tickets.', 16, 1);
        RETURN;
    END

    DECLARE @ERM_TicketID BIGINT, @StatusID TINYINT, @PrevAssignee NVARCHAR(200), @PrevAssigneeId INT;

    SELECT @ERM_TicketID = ERM_TicketID, @StatusID = StatusID,
           @PrevAssignee = AssignedToUserName, @PrevAssigneeId = AssignedToUserProfileID
    FROM ERM.ERM_Ticket WHERE TicketNumber = @TicketNumber;

    IF @ERM_TicketID IS NULL
    BEGIN
        RAISERROR (N'Ticket %s does not exist.', 16, 1, @TicketNumber);
        RETURN;
    END

    DECLARE @unassigning BIT = CASE WHEN @AssignToUserProfileID IS NULL THEN 1 ELSE 0 END;

    DECLARE @targetId INT, @targetName NVARCHAR(200), @targetDisplay NVARCHAR(200);

    IF @unassigning = 0
    BEGIN
        /* Resolve against the roster, and fail if the target is not a real,
           active, assignable person. */
        SELECT TOP 1 @targetId = su.UserProfileID, @targetName = su.UserName, @targetDisplay = su.DisplayName
        FROM ERM.ERM_SupportUser su
        JOIN ERM.ERM_SupportRole r ON r.RoleID = su.RoleID
        WHERE su.IsActive = 1 AND r.IsActive = 1 AND r.CanBeAssigned = 1
          AND su.UserProfileID = @AssignToUserProfileID;

        IF @targetDisplay IS NULL
        BEGIN
            RAISERROR (N'Assignee is not an active, assignable member of the support roster.', 16, 1);
            RETURN;
        END
    END

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRANSACTION;

        UPDATE ERM.ERM_Ticket
           SET AssignedToUserProfileID = @targetId,
               AssignedToUserName = @targetName,
               UpdatedBy          = ISNULL(@ChangedByUserProfileID, ERM.fn_SystemUserID()),
               UpdatedDate        = GETUTCDATE(),
               AssignedUtc        = CASE WHEN @unassigning = 1 THEN NULL
                                         ELSE ISNULL(AssignedUtc, @Now) END,
               /* An assignment is a response: somebody has picked the ticket
                  up. Setting it here means first-response time is not
                  understated just because nobody changed the status yet. */
               FirstResponseUtc   = CASE WHEN @unassigning = 1 THEN FirstResponseUtc
                                         ELSE ISNULL(FirstResponseUtc, @Now) END
         WHERE ERM_TicketID = @ERM_TicketID;

        DECLARE @SeqNo INT;
        SELECT @SeqNo = ISNULL(MAX(SequenceNo), 0) + 1
        FROM ERM.ERM_TicketStatusHistory WITH (UPDLOCK, HOLDLOCK)
        WHERE ERM_TicketID = @ERM_TicketID;

        INSERT ERM.ERM_TicketStatusHistory
            (ERM_TicketID, SequenceNo, FromStatusID, ToStatusID, ChangedByUserProfileID, ChangedByUserName,
             ChangedUtc, MinutesInFromStatus, Comments, IsCustomerVisible,
             AssignedToUserProfileID, AssignedToUserName, PreviousAssignedToUserName, ChangeKind,
             CreatedBy)
        VALUES
            (@ERM_TicketID, @SeqNo,
             /* Same status on both sides: this row records an ASSIGNMENT, not a
                transition, and pretending otherwise would corrupt the
                minutes-in-status accounting. */
             @StatusID, @StatusID,
             ISNULL(@ChangedByUserProfileID, ERM.fn_SystemUserID()), @ChangedByUserName, @Now,
             NULL,
             COALESCE(@Comments,
                      CASE WHEN @unassigning = 1 THEN N'Ticket unassigned.'
                           WHEN @PrevAssignee IS NULL THEN N'Assigned to ' + @targetDisplay + N'.'
                           ELSE N'Reassigned from ' + @PrevAssignee + N' to ' + @targetDisplay + N'.' END),
             /* Internal: which engineer holds the ticket is not the end user's
                business, and telling them invites them to chase that person. */
             0,
             @targetId, @targetName, @PrevAssignee, N'assignment',
             ISNULL(@ChangedByUserProfileID, ERM.fn_SystemUserID()));

    COMMIT TRANSACTION;

    /* Advance New -> Assigned as a separate, properly audited transition, so
       the status history and the minutes-in-status accounting stay correct. */
    IF @unassigning = 0 AND @AdvanceStatus = 1
    BEGIN
        DECLARE @AssignedStatusId TINYINT =
            (SELECT StatusID FROM ERM.ERM_TicketStatus WHERE Code = N'assigned' AND IsActive = 1);

        IF @AssignedStatusId IS NOT NULL
           AND @StatusID <> @AssignedStatusId
           AND EXISTS (SELECT 1 FROM ERM.ERM_TicketStatusTransition
                       WHERE FromStatusID = @StatusID AND ToStatusID = @AssignedStatusId
                         AND IsActive = 1)
        BEGIN
            EXEC ERM.usp_Ticket_ChangeStatus
                 @ERM_TicketID          = @ERM_TicketID,
                 @ToStatusID        = @AssignedStatusId,
                 @ChangedByUserProfileID = @ChangedByUserProfileID,
                 @ChangedByUserName = @ChangedByUserName,
                 @Comments          = N'Assigned.',
                 @AssignToUserProfileID = @targetId,
                 @AssignToUserName  = @targetName,
                 @IsCustomerVisible = 1;
        END
    END

    /* The person who has just been given the work is the one who needs to
       know. The reporter is told about STATUS, not about which engineer holds
       their ticket - see the IsCustomerVisible = 0 on the history row above. */
    IF @unassigning = 0 AND OBJECT_ID(N'ERM.usp_Notification_Enqueue', N'P') IS NOT NULL
        EXEC ERM.usp_Notification_Enqueue
             @RecipientUserProfileID = @targetId,
             @EventKind    = N'assigned',
             @ERM_TicketID = @ERM_TicketID,
             @TicketNumber = @TicketNumber,
             @Title        = N'A support ticket has been assigned to you',
             @Body         = @TicketNumber,
             @ActedByUserProfileID = @ChangedByUserProfileID;

    SELECT @TicketNumber AS TicketNumber,
           @targetName AS AssignedToUserName,
           @targetDisplay AS AssignedToDisplayName,
           @PrevAssignee AS PreviousAssignedToUserName,
           @SeqNo AS SequenceNo;
END
GO

/* usp_Ticket_ChangeStatus records the assignee on its history row too, so the
   audit trail is complete whichever route was used. */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_RecordAssigneeOnHistory
(
    @ERM_TicketID BIGINT,
    @SequenceNo INT
)
AS
BEGIN
    SET NOCOUNT ON;
    /* Back-fills the assignee columns on a status-history row from the ticket's
       current state. Called by usp_Ticket_ChangeStatus immediately after it
       writes its row, so the two stay consistent without duplicating the
       assignment logic. */
    UPDATE h
       SET h.AssignedToUserProfileID = t.AssignedToUserProfileID,
           h.AssignedToUserName = t.AssignedToUserName
      FROM ERM.ERM_TicketStatusHistory h
      JOIN ERM.ERM_Ticket t ON t.ERM_TicketID = h.ERM_TicketID
     WHERE h.ERM_TicketID = @ERM_TicketID AND h.SequenceNo = @SequenceNo;
END
GO

/* =============================================================================
   PART 3 - Manually raised tickets (no captured error)
   ============================================================================= */

/* A ticket no longer has to hang off a fingerprint. */
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID(N'ERM.ERM_Ticket')
             AND name = N'ERM_ErrorFingerprintID' AND is_nullable = 0)
BEGIN
    /* The FK stays; only the nullability changes. Relaxing NOT NULL cannot
       fail on existing rows, so this is safe on a live table. */
    ALTER TABLE ERM.ERM_Ticket ALTER COLUMN ERM_ErrorFingerprintID BIGINT NULL;
END
GO

/* Where the ticket came from, so the console can tell a captured fault from a
   request somebody typed. CreatedVia already distinguished user/auto_rule/admin
   but every value implied an underlying error. */
IF COL_LENGTH(N'ERM.ERM_Ticket', N'TicketSource') IS NULL
    ALTER TABLE ERM.ERM_Ticket
        ADD TicketSource NVARCHAR(20) NOT NULL
            CONSTRAINT DF_Ticket_Source DEFAULT (N'error');
GO

/* What the user says the problem is about, for a manual ticket where there is
   no module/screen to infer from an occurrence. */
IF COL_LENGTH(N'ERM.ERM_Ticket', N'RequestCategory') IS NULL
    ALTER TABLE ERM.ERM_Ticket ADD RequestCategory NVARCHAR(60) NULL;
GO

IF COL_LENGTH(N'ERM.ERM_Ticket', N'ReportedScreen') IS NULL
    ALTER TABLE ERM.ERM_Ticket ADD ReportedScreen NVARCHAR(200) NULL;
GO

/* Either it came from an error and has a fingerprint, or it is manual and does
   not. A ticket that is neither is a bug, and a CHECK constraint is how you
   find out at the INSERT rather than three screens later. */
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Ticket_SourceIntegrity')
    ALTER TABLE ERM.ERM_Ticket WITH NOCHECK
        ADD CONSTRAINT CK_Ticket_SourceIntegrity CHECK
        (
            (TicketSource = N'error'  AND ERM_ErrorFingerprintID IS NOT NULL)
         OR (TicketSource = N'manual' AND ERM_ErrorFingerprintID IS NULL)
        );
GO

/* Categories an end user can pick when raising a ticket by hand. Rows, not an
   enum, so support can change the list without a release. */
IF OBJECT_ID(N'ERM.ERM_RequestCategory', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_RequestCategory
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_RequestCategory_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_RequestCategory_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_RequestCategory_AppNo DEFAULT (1),
        Code            NVARCHAR(60)    NOT NULL,
        DisplayName     NVARCHAR(120)   NOT NULL,
        DefaultSeverityID TINYINT       NOT NULL,
        DefaultQueueID  SMALLINT        NULL,
        RankOrder       TINYINT         NOT NULL CONSTRAINT DF_RequestCategory_Rank DEFAULT (50),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_RequestCategory_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_RequestCategory_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_RequestCategory_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_RequestCategory PRIMARY KEY CLUSTERED (Code),
        CONSTRAINT FK_RequestCategory_Severity FOREIGN KEY (DefaultSeverityID)
            REFERENCES ERM.ERM_Severity (SeverityID),
        CONSTRAINT FK_RequestCategory_Queue FOREIGN KEY (DefaultQueueID)
            REFERENCES ERM.ERM_TicketQueue (ERM_TicketQueueID)
    );
END
GO

MERGE ERM.ERM_RequestCategory AS t
USING (VALUES
    (N'wrong_data',      N'Data looks wrong or is missing',      3, 10),
    (N'cannot_complete', N'I cannot complete a task',            2, 20),
    (N'slow',            N'Something is very slow',              3, 30),
    (N'access',          N'I need access to something',          4, 40),
    (N'how_to',          N'I need help using a screen',          4, 50),
    (N'enhancement',     N'Suggestion or enhancement request',   5, 60),
    (N'other',           N'Something else',                      4, 99)
) AS s (Code, DisplayName, DefaultSeverityID, RankOrder)
    ON t.Code = s.Code
WHEN NOT MATCHED THEN
    INSERT (Code, DisplayName, DefaultSeverityID, RankOrder, CreatedBy)
    VALUES (s.Code, s.DisplayName, s.DefaultSeverityID, s.RankOrder, ERM.fn_SystemUserID());
GO

CREATE OR ALTER PROCEDURE ERM.usp_RequestCategory_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT rc.Code, rc.DisplayName, sv.Code AS DefaultSeverityCode, rc.RankOrder
    FROM ERM.ERM_RequestCategory rc
    JOIN ERM.ERM_Severity sv ON sv.SeverityID = rc.DefaultSeverityID
    WHERE rc.IsActive = 1
    ORDER BY rc.RankOrder, rc.DisplayName;
END
GO

/* -----------------------------------------------------------------------------
   usp_Ticket_CreateManual
   -----------------------------------------------------------------------------
   A ticket raised by a user with no captured error behind it.

   Deliberately NOT deduplicated. Fingerprint deduplication answers "is this
   the same fault?", and there is no fault here - two people describing the same
   annoyance in their own words are two requests, and merging them would lose
   one person's description and confuse both. Recurring-problem analysis
   therefore ignores manual tickets, which is correct: they are not errors.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_CreateManual
(
    @Title              NVARCHAR(400),
    @Description        NVARCHAR(MAX),
    @RequestCategory    NVARCHAR(60)  = N'other',
    @ErpModule          NVARCHAR(100) = NULL,
    @ReportedScreen     NVARCHAR(200) = NULL,
    @Environment        NVARCHAR(40)  = NULL,
    @ReportedByUserProfileID INT      = NULL,
    @ReportedByUserName NVARCHAR(200) = NULL,
    /* Support staff raising one on a user's behalf - phone call, corridor
       conversation. The ticket is owned by @ReportedByUserProfileID so it
       appears in THEIR My Tickets, not the agent's. */
    @CreatedVia         NVARCHAR(20)  = N'user',
    @SeverityCode       NVARCHAR(20)  = NULL,
    @TicketNumber       VARCHAR(30)   OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Title IS NULL OR LEN(LTRIM(RTRIM(@Title))) = 0
    BEGIN
        RAISERROR (N'A title is required.', 16, 1);
        RETURN;
    END

    IF @ReportedByUserProfileID IS NULL OR @ReportedByUserProfileID <= 0
    BEGIN
        /* An unowned manual ticket cannot appear in anyone's My Tickets and
           nobody can be asked for more information - it is a dead record.
           -1 counts as unowned: the non-user value is not a person who can be
           asked anything. */
        RAISERROR (N'A manual ticket must have a real ERP user as its owner.', 16, 1);
        RETURN;
    END

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    DECLARE @catCode NVARCHAR(60) =
        ISNULL((SELECT Code FROM ERM.ERM_RequestCategory
                WHERE Code = @RequestCategory AND IsActive = 1), N'other');

    DECLARE @SeverityID TINYINT = COALESCE(
        (SELECT SeverityID FROM ERM.ERM_Severity WHERE Code = @SeverityCode AND IsActive = 1),
        (SELECT DefaultSeverityID FROM ERM.ERM_RequestCategory WHERE Code = @catCode),
        4 /* low */);

    DECLARE @ERM_TicketQueueID SMALLINT = COALESCE(
        (SELECT DefaultQueueID FROM ERM.ERM_RequestCategory WHERE Code = @catCode),
        (SELECT TOP 1 ERM_TicketQueueID FROM ERM.ERM_TicketQueue
         WHERE IsActive = 1 AND ErpModuleMatch = @ErpModule ORDER BY ERM_TicketQueueID),
        (SELECT TOP 1 ERM_TicketQueueID FROM ERM.ERM_TicketQueue
         WHERE IsActive = 1 AND IsDefault = 1 ORDER BY ERM_TicketQueueID),
        (SELECT TOP 1 ERM_TicketQueueID FROM ERM.ERM_TicketQueue WHERE IsActive = 1 ORDER BY ERM_TicketQueueID));

    DECLARE @ERM_SlaPolicyID SMALLINT =
        COALESCE((SELECT TOP 1 ERM_SlaPolicyID FROM ERM.ERM_SlaPolicy
                  WHERE IsActive = 1 AND SeverityID = @SeverityID AND ERM_TicketQueueID = @ERM_TicketQueueID),
                 (SELECT TOP 1 ERM_SlaPolicyID FROM ERM.ERM_SlaPolicy
                  WHERE IsActive = 1 AND SeverityID = @SeverityID AND ERM_TicketQueueID IS NULL));

    EXEC ERM.usp_NextReference @RefType = 'TKT', @Reference = @TicketNumber OUTPUT;

    DECLARE @NewTicketId BIGINT;

    BEGIN TRANSACTION;

        INSERT ERM.ERM_Ticket
        (
            TicketNumber, ERM_ErrorOccurrenceID, ERM_ErrorFingerprintID, StatusID, SeverityID, ERM_TicketQueueID, ERM_SlaPolicyID,
            Title, UserDescription, ReportedByUserProfileID, ReportedByUserName, CreatedVia,
            ErpModule, Environment, CreatedUtc, LastStatusChangeUtc, LinkedOccurrenceCount,
            TicketSource, RequestCategory, ReportedScreen, CreatedBy
        )
        VALUES
        (
            @TicketNumber, NULL, NULL, 1 /*new*/, @SeverityID, @ERM_TicketQueueID, @ERM_SlaPolicyID,
            LEFT(LTRIM(RTRIM(@Title)), 400), @Description, @ReportedByUserProfileID, @ReportedByUserName,
            @CreatedVia, @ErpModule, @Environment, @Now, @Now,
            /* No occurrences behind it. */
            0,
            N'manual', @catCode, @ReportedScreen, @ReportedByUserProfileID
        );

        SET @NewTicketId = SCOPE_IDENTITY();

        INSERT ERM.ERM_TicketStatusHistory
            (ERM_TicketID, SequenceNo, FromStatusID, ToStatusID, ChangedByUserProfileID, ChangedByUserName,
             ChangedUtc, MinutesInFromStatus, Comments, IsCustomerVisible, ChangeKind, CreatedBy)
        VALUES
            (@NewTicketId, 1, NULL, 1, @ReportedByUserProfileID, @ReportedByUserName, @Now, NULL,
             N'Ticket raised manually by the user.', 1, N'status', @ReportedByUserProfileID);

    COMMIT TRANSACTION;

    IF OBJECT_ID(N'ERM.usp_Notification_Enqueue', N'P') IS NOT NULL
        EXEC ERM.usp_Notification_Enqueue
             @RecipientUserProfileID = @ReportedByUserProfileID,
             @EventKind    = N'created',
             @ERM_TicketID = @NewTicketId,
             @TicketNumber = @TicketNumber,
             @Title        = N'Your request has been logged',
             @Body         = @Title,
             @ActedByUserProfileID = NULL;

    SELECT @TicketNumber AS TicketNumber, @NewTicketId AS TicketId,
           CONVERT(BIT, 0) AS WasDeduplicated;
END
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'011_support_access_and_manual_tickets.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.3.0', ERM.fn_SystemUserID());
GO

GO

/* ==========================================================================
   SCRIPT: 012_notifications.sql
   ========================================================================== */
GO
PRINT '--- 012_notifications.sql ---';
GO

/* =============================================================================
   ERP Error Management Framework
   Script 012 - Ticket notifications, delivered through the ERP's OWN system

   WHAT ATC ASKED FOR
   ------------------
   "We already have an existing ERP notification system for logged-in users...
    we do not want to introduce Teams or a separate SMTP notification system.
    The ERM framework should integrate with our existing ERP notification
    mechanism where applicable."

   So this script adds no delivery channel at all. It adds the two things that
   are actually missing:

     1. a record of WHAT should be notified, and to WHOM - the outbox;
     2. ONE procedure, ERM.usp_Notification_ErpAdapter, which is the single
        place the ERP's own notification call goes.

   WHY AN OUTBOX AND NOT A DIRECT CALL
   -----------------------------------
   The obvious implementation is to call the notification system from inside
   usp_Ticket_ChangeStatus. Do not. That call would then run INSIDE the ticket
   transaction, which means:

     * if the notification system is slow, changing a ticket's status is slow;
     * if it throws, the status change ROLLS BACK - a notification failure
       would undo the work it was supposed to announce.

   An outbox row is written in the same transaction (so it is exactly as
   durable as the status change, and never announces something that did not
   happen), and delivery is a separate step that can fail, retry and be
   monitored without touching the ticket.

   WHY IT IS NOT DYNAMIC SQL
   -------------------------
   An earlier draft read the target procedure's NAME from a settings row and
   called it with sp_executesql, so it could be pointed anywhere without an
   ALTER. That is a configurable remote-code-execution hole in the one schema
   that holds every stack trace in the system, bought to save one ALTER
   PROCEDURE. There is exactly one ERP here. One adapter procedure, edited
   once, is simpler, safer, and easier to read six months from now.

   Idempotent: yes.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ------------------------------------------------------------- the outbox -- */
IF OBJECT_ID(N'ERM.ERM_NotificationOutbox', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_NotificationOutbox
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_NotificationOutbox_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_NotificationOutbox_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_NotificationOutbox_AppNo DEFAULT (1),

        ERM_NotificationOutboxID BIGINT IDENTITY(1,1) NOT NULL,

        /* Who should see it. The ERP UserProfileID - never a name, never an
           address. The ERP's notification system already knows how to reach a
           user; that is precisely why we are using it rather than inventing a
           channel. */
        RecipientUserProfileID INT      NOT NULL,

        /* What happened. 'created' | 'status_changed' | 'assigned' |
           'support_comment' | 'resolved' | 'closed' */
        EventKind       NVARCHAR(30)    NOT NULL,

        ERM_TicketID    BIGINT          NULL,
        TicketNumber    VARCHAR(30)     NULL,

        Title           NVARCHAR(200)   NOT NULL,
        /* Safe, user-facing text. No stack traces, no SQL, no object names -
           the whole point of the framework is that the user never sees those,
           and a notification is still the user seeing something. */
        Body            NVARCHAR(1000)  NOT NULL,
        /* Deep link into the ERP's My Issues panel, if the host wants one. */
        LinkUrl         NVARCHAR(400)   NULL,

        /* pending | sent | failed | skipped */
        DeliveryState   NVARCHAR(20)    NOT NULL CONSTRAINT DF_NotificationOutbox_State DEFAULT (N'pending'),
        AttemptCount    INT             NOT NULL CONSTRAINT DF_NotificationOutbox_Attempts DEFAULT (0),
        LastAttemptUtc  DATETIME2(3)    NULL,
        DeliveredUtc    DATETIME2(3)    NULL,
        LastError       NVARCHAR(2000)  NULL,

        QueuedUtc       DATETIME2(3)    NOT NULL CONSTRAINT DF_NotificationOutbox_Queued DEFAULT (SYSUTCDATETIME()),

        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_NotificationOutbox_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_NotificationOutbox_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_NotificationOutbox_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,

        CONSTRAINT PK_NotificationOutbox PRIMARY KEY CLUSTERED (ERM_NotificationOutboxID),
        /* The non-user value cannot receive a notification, because it is not a
           person. Enforced rather than assumed: an auto-rule ticket has -1 as
           its reporter, and without this every one of those would queue an
           undeliverable row for ever. */
        CONSTRAINT CK_NotificationOutbox_RealUser CHECK (RecipientUserProfileID > 0)
    );

    /* The dispatcher's query: pending rows, oldest first. Filtered, so the
       index stays small no matter how much history accumulates. */
    CREATE INDEX IX_NotificationOutbox_Pending
        ON ERM.ERM_NotificationOutbox (QueuedUtc)
        WHERE DeliveryState = N'pending';

    CREATE INDEX IX_NotificationOutbox_Ticket
        ON ERM.ERM_NotificationOutbox (ERM_TicketID, QueuedUtc DESC);
END
GO

/* =============================================================================
   THE ONE PLACE YOU EDIT
   -----------------------------------------------------------------------------
   Replace the body of this procedure with the call into the ERP's existing
   notification system. Nothing else in the framework needs to change, and
   nothing else calls the ERP's notification system.

   It ships as a NO-OP that reports "not wired up yet" rather than as a guess at
   your signature. A stub that pretends to succeed would mean the outbox showed
   every row as delivered while nobody was ever notified - which is the failure
   mode you would discover from a user complaint, months later.

   Typical body once wired up:

       EXEC dbo.usp_LS_Notification_Create
            @UserProfileID = @RecipientUserProfileID,
            @Subject       = @Title,
            @Message       = @Body,
            @Url           = @LinkUrl,
            @CreatedBy     = @RecipientUserProfileID;
       SET @Delivered = 1;

   CONTRACT
     * Set @Delivered = 1 only when the notification is genuinely recorded.
     * Set @FailureReason when it is not; the dispatcher stores it and retries.
     * Do NOT open a transaction here - you are already inside the dispatcher's.
     * Do NOT throw for an expected condition (user has notifications off, say):
       set @Delivered = 0 with a reason, or 1 if "no notification wanted" counts
       as handled. Throwing is reserved for genuine faults.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Notification_ErpAdapter
(
    @RecipientUserProfileID INT,
    @EventKind      NVARCHAR(30),
    @TicketNumber   VARCHAR(30),
    @Title          NVARCHAR(200),
    @Body           NVARCHAR(1000),
    @LinkUrl        NVARCHAR(400)  = NULL,
    @Delivered      BIT            OUTPUT,
    @FailureReason  NVARCHAR(2000) OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    /* ---------------------------------------------------------------------
       REPLACE EVERYTHING BELOW THIS LINE with the call into your own
       notification system.
       --------------------------------------------------------------------- */

    SET @Delivered = 0;
    SET @FailureReason =
        N'ERM.usp_Notification_ErpAdapter has not been wired up to the ERP '
      + N'notification system yet. See db/012_notifications.sql.';
END
GO

/* -----------------------------------------------------------------------------
   Enqueue. Called from inside the ticket procedures, in their transaction.

   Silently does nothing when there is no real recipient. That is the common
   case, not an error: a ticket raised by an automatic rule has -1 as its
   reporter, and there is nobody to tell.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Notification_Enqueue
(
    @RecipientUserProfileID INT,
    @EventKind      NVARCHAR(30),
    @ERM_TicketID   BIGINT,
    @TicketNumber   VARCHAR(30),
    @Title          NVARCHAR(200),
    @Body           NVARCHAR(1000),
    @LinkUrl        NVARCHAR(400) = NULL,
    @ActedByUserProfileID INT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF ERM.fn_SettingBit(N'notify.onStatusChange', 1) = 0 RETURN;

    /* Not a person: nothing to deliver, and the CHECK constraint would reject
       the row anyway. */
    IF @RecipientUserProfileID IS NULL OR @RecipientUserProfileID <= 0 RETURN;

    /* Do not notify somebody about their own action. The user who just typed a
       reply does not need telling that a reply was typed, and support does not
       need telling they assigned the ticket they just assigned. */
    IF @ActedByUserProfileID IS NOT NULL AND @ActedByUserProfileID = @RecipientUserProfileID RETURN;

    INSERT ERM.ERM_NotificationOutbox
        (RecipientUserProfileID, EventKind, ERM_TicketID, TicketNumber,
         Title, Body, LinkUrl, CreatedBy)
    VALUES
        (@RecipientUserProfileID, @EventKind, @ERM_TicketID, @TicketNumber,
         LEFT(@Title, 200), LEFT(@Body, 1000), @LinkUrl,
         ISNULL(@ActedByUserProfileID, ERM.fn_SystemUserID()));
END
GO

/* -----------------------------------------------------------------------------
   Dispatch. Run from SQL Agent, or from the API on a timer - either is fine.

   Each row is delivered in its own transaction, so one bad row cannot roll back
   a batch, and a kill mid-run loses nothing.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Notification_Dispatch
(
    @BatchSize   INT = 200,
    /* Rows that have failed this many times stop being retried. Without this a
       permanently undeliverable row is attempted for ever, and the dispatcher
       spends its life on it instead of on new notifications. */
    @MaxAttempts INT = 5
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @BatchSize IS NULL OR @BatchSize < 1 SET @BatchSize = 200;
    IF @BatchSize > 2000 SET @BatchSize = 2000;

    DECLARE @Pending TABLE
    (
        ERM_NotificationOutboxID BIGINT,
        RecipientUserProfileID INT,
        EventKind      NVARCHAR(30),
        TicketNumber   VARCHAR(30),
        Title          NVARCHAR(200),
        Body           NVARCHAR(1000),
        LinkUrl        NVARCHAR(400)
    );

    INSERT @Pending
    SELECT TOP (@BatchSize)
           ERM_NotificationOutboxID, RecipientUserProfileID, EventKind,
           TicketNumber, Title, Body, LinkUrl
    FROM ERM.ERM_NotificationOutbox
    WHERE DeliveryState = N'pending'
      AND AttemptCount < @MaxAttempts
    ORDER BY QueuedUtc;

    DECLARE @Id BIGINT, @Recipient INT, @Kind NVARCHAR(30), @Ticket VARCHAR(30),
            @Title NVARCHAR(200), @Body NVARCHAR(1000), @Link NVARCHAR(400);
    DECLARE @Delivered BIT, @Reason NVARCHAR(2000);
    DECLARE @Sent INT = 0, @Failed INT = 0;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT ERM_NotificationOutboxID, RecipientUserProfileID, EventKind,
               TicketNumber, Title, Body, LinkUrl
        FROM @Pending;

    OPEN c;
    FETCH NEXT FROM c INTO @Id, @Recipient, @Kind, @Ticket, @Title, @Body, @Link;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Delivered = 0;
        SET @Reason = NULL;

        BEGIN TRY
            EXEC ERM.usp_Notification_ErpAdapter
                 @RecipientUserProfileID = @Recipient,
                 @EventKind      = @Kind,
                 @TicketNumber   = @Ticket,
                 @Title          = @Title,
                 @Body           = @Body,
                 @LinkUrl        = @Link,
                 @Delivered      = @Delivered OUTPUT,
                 @FailureReason  = @Reason    OUTPUT;
        END TRY
        BEGIN CATCH
            SET @Delivered = 0;
            SET @Reason = CONCAT(N'Adapter threw: Msg ', ERROR_NUMBER(),
                                 N', Line ', ERROR_LINE(), N': ', ERROR_MESSAGE());
        END CATCH

        UPDATE ERM.ERM_NotificationOutbox
           SET DeliveryState  = CASE WHEN @Delivered = 1 THEN N'sent'
                                     WHEN AttemptCount + 1 >= @MaxAttempts THEN N'failed'
                                     ELSE N'pending' END,
               AttemptCount   = AttemptCount + 1,
               LastAttemptUtc = SYSUTCDATETIME(),
               DeliveredUtc   = CASE WHEN @Delivered = 1 THEN SYSUTCDATETIME() ELSE DeliveredUtc END,
               LastError      = CASE WHEN @Delivered = 1 THEN NULL ELSE LEFT(@Reason, 2000) END,
               UpdatedBy      = ERM.fn_SystemUserID(),
               UpdatedDate    = GETUTCDATE()
         WHERE ERM_NotificationOutboxID = @Id;

        IF @Delivered = 1 SET @Sent += 1; ELSE SET @Failed += 1;

        FETCH NEXT FROM c INTO @Id, @Recipient, @Kind, @Ticket, @Title, @Body, @Link;
    END

    CLOSE c;
    DEALLOCATE c;

    SELECT @Sent AS Sent, @Failed AS Failed,
           (SELECT COUNT_BIG(*) FROM ERM.ERM_NotificationOutbox
            WHERE DeliveryState = N'pending' AND AttemptCount < @MaxAttempts) AS StillPending;
END
GO

/* -----------------------------------------------------------------------------
   What the console shows about delivery. Chiefly: is anything stuck?
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Notification_Status
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DeliveryState,
           COUNT_BIG(*)       AS RowCountValue,
           MIN(QueuedUtc)     AS OldestQueuedUtc,
           MAX(LastAttemptUtc) AS LastAttemptUtc
    FROM ERM.ERM_NotificationOutbox
    GROUP BY DeliveryState
    ORDER BY DeliveryState;

    /* The one that matters: the adapter is not wired up, so nothing is being
       delivered. Surfaced rather than left to be noticed. */
    SELECT TOP 20 ERM_NotificationOutboxID, TicketNumber, EventKind,
                  RecipientUserProfileID, AttemptCount, LastError, QueuedUtc
    FROM ERM.ERM_NotificationOutbox
    WHERE DeliveryState IN (N'failed', N'pending')
      AND LastError IS NOT NULL
    ORDER BY QueuedUtc DESC;
END
GO

/* Retention: notifications are the most disposable thing in the schema - once
   delivered, the ticket history is the record, not the announcement. */
MERGE ERM.ERM_RetentionPolicy AS t
USING (SELECT N'notification' AS DataSet, 30 AS ArchiveAfterDays,
              90 AS PurgeAfterDays, 5000 AS BatchSize) AS s
    ON t.DataSet = s.DataSet
WHEN NOT MATCHED THEN
    INSERT (DataSet, ArchiveAfterDays, PurgeAfterDays, BatchSize, CreatedBy)
    VALUES (s.DataSet, s.ArchiveAfterDays, s.PurgeAfterDays, s.BatchSize, ERM.fn_SystemUserID());
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'012_notifications.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.4.0', ERM.fn_SystemUserID());
GO

GO

PRINT '=== ERM install complete. Now run VERIFY.sql ===';
GO
