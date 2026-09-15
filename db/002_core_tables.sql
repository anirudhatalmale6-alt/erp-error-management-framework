/* =============================================================================
   ERP Error Management Framework
   Script 002 - Core tables: fingerprints, occurrences, tickets, audit trail
   Idempotent: yes
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* --------------------------------------------------------------- numbering */
/* Human-facing reference numbers.  A SEQUENCE (not IDENTITY, not MAX()+1) so
   the number can be reserved inside the same transaction that writes the row
   without serialising writers or leaving gaps that matter.                    */
IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE object_id = OBJECT_ID(N'erp_err.ErrorNumberSeq'))
    CREATE SEQUENCE erp_err.ErrorNumberSeq  AS BIGINT START WITH 1 INCREMENT BY 1 CACHE 50;
GO
IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE object_id = OBJECT_ID(N'erp_err.TicketNumberSeq'))
    CREATE SEQUENCE erp_err.TicketNumberSeq AS BIGINT START WITH 1 INCREMENT BY 1 CACHE 50;
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
IF OBJECT_ID(N'erp_err.ErrorFingerprint', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.ErrorFingerprint
    (
        FingerprintId       BIGINT          IDENTITY(1,1) NOT NULL,
        -- SHA-256 of the normalised signature, lower-case hex, 64 chars.
        FingerprintHash     CHAR(64)        NOT NULL,
        -- The human-readable signature the hash was taken over, kept so an
        -- admin can see WHY two errors were considered the same.
        SignatureText       NVARCHAR(1000)  NOT NULL,

        LayerId             TINYINT         NOT NULL,
        CategoryId          SMALLINT        NOT NULL,
        SeverityId          TINYINT         NOT NULL,

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
        OpenTicketId        BIGINT          NULL,
        Notes               NVARCHAR(MAX)   NULL,

        CONSTRAINT PK_ErrorFingerprint PRIMARY KEY CLUSTERED (FingerprintId),
        CONSTRAINT UQ_ErrorFingerprint_Hash UNIQUE (FingerprintHash),
        CONSTRAINT FK_Fingerprint_Layer    FOREIGN KEY (LayerId)    REFERENCES erp_err.AppLayer (LayerId),
        CONSTRAINT FK_Fingerprint_Category FOREIGN KEY (CategoryId) REFERENCES erp_err.ErrorCategory (CategoryId),
        CONSTRAINT FK_Fingerprint_Severity FOREIGN KEY (SeverityId) REFERENCES erp_err.Severity (SeverityId)
    );

    CREATE INDEX IX_Fingerprint_LastSeen  ON erp_err.ErrorFingerprint (LastSeenUtc DESC) INCLUDE (OccurrenceCount, SeverityId, TriageState);
    CREATE INDEX IX_Fingerprint_Module    ON erp_err.ErrorFingerprint (ErpModule, LastSeenUtc DESC);
    CREATE INDEX IX_Fingerprint_Triage    ON erp_err.ErrorFingerprint (TriageState, SeverityId) INCLUDE (LastSeenUtc, OccurrenceCount);
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
IF OBJECT_ID(N'erp_err.ErrorOccurrence', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.ErrorOccurrence
    (
        OccurrenceId        BIGINT          IDENTITY(1,1) NOT NULL,
        -- Shown to the user in the modal, e.g. 'ERR-2026-00004821'.
        ErrorReference      VARCHAR(24)     NOT NULL,
        FingerprintId       BIGINT          NOT NULL,

        /* ---- when ---- */
        OccurredUtc         DATETIME2(3)    NOT NULL,
        -- Client wall-clock + offset, kept separately: a user report says
        -- "it broke at 2pm" and 2pm is local, not UTC.
        OccurredLocal       DATETIME2(3)    NULL,
        ClientUtcOffsetMin  SMALLINT        NULL,
        ReceivedUtc         DATETIME2(3)    NOT NULL CONSTRAINT DF_Occurrence_Received DEFAULT (SYSUTCDATETIME()),

        /* ---- what ---- */
        LayerId             TINYINT         NOT NULL,
        CategoryId          SMALLINT        NOT NULL,
        SeverityId          TINYINT         NOT NULL,
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

        /* ---- who ---- */
        UserId              NVARCHAR(128)   NULL,
        UserName            NVARCHAR(200)   NULL,
        UserDisplayName     NVARCHAR(200)   NULL,
        TenantId            NVARCHAR(64)    NULL,
        SessionId           NVARCHAR(100)   NULL,
        ClientIp            NVARCHAR(64)    NULL,

        /* ---- correlation ---- */
        -- Generated in the browser, forwarded on every hop, so an Angular
        -- error, its HTTP failure, the .NET exception and the SQL error all
        -- carry the same value and can be assembled into one incident view.
        CorrelationId       UNIQUEIDENTIFIER NOT NULL,
        -- Identifies this single HTTP request within the correlation.
        RequestId           UNIQUEIDENTIFIER NULL,
        -- Set when this occurrence was raised as a direct consequence of
        -- another (e.g. the Angular HTTP error whose cause is the .NET one).
        ParentOccurrenceId  BIGINT          NULL,

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
        TicketId            BIGINT          NULL,

        CONSTRAINT PK_ErrorOccurrence PRIMARY KEY CLUSTERED (OccurrenceId),
        CONSTRAINT UQ_ErrorOccurrence_Reference UNIQUE (ErrorReference),
        CONSTRAINT FK_Occurrence_Fingerprint FOREIGN KEY (FingerprintId) REFERENCES erp_err.ErrorFingerprint (FingerprintId),
        CONSTRAINT FK_Occurrence_Layer       FOREIGN KEY (LayerId)       REFERENCES erp_err.AppLayer (LayerId),
        CONSTRAINT FK_Occurrence_Category    FOREIGN KEY (CategoryId)    REFERENCES erp_err.ErrorCategory (CategoryId),
        CONSTRAINT FK_Occurrence_Severity    FOREIGN KEY (SeverityId)    REFERENCES erp_err.Severity (SeverityId),
        CONSTRAINT FK_Occurrence_Parent      FOREIGN KEY (ParentOccurrenceId) REFERENCES erp_err.ErrorOccurrence (OccurrenceId)
    );

    CREATE INDEX IX_Occurrence_OccurredUtc  ON erp_err.ErrorOccurrence (OccurredUtc DESC)
        INCLUDE (FingerprintId, SeverityId, LayerId, ErpModule, UserName, TicketId);
    CREATE INDEX IX_Occurrence_Fingerprint  ON erp_err.ErrorOccurrence (FingerprintId, OccurredUtc DESC);
    CREATE INDEX IX_Occurrence_Correlation  ON erp_err.ErrorOccurrence (CorrelationId, OccurredUtc);
    CREATE INDEX IX_Occurrence_User         ON erp_err.ErrorOccurrence (UserName, OccurredUtc DESC);
    CREATE INDEX IX_Occurrence_Module       ON erp_err.ErrorOccurrence (ErpModule, Screen, OccurredUtc DESC);
    CREATE INDEX IX_Occurrence_Api          ON erp_err.ErrorOccurrence (ApiController, ApiAction, OccurredUtc DESC);
    CREATE INDEX IX_Occurrence_Sql          ON erp_err.ErrorOccurrence (SqlErrorNumber, OccurredUtc DESC) WHERE SqlErrorNumber IS NOT NULL;
    CREATE INDEX IX_Occurrence_Ticket       ON erp_err.ErrorOccurrence (TicketId) WHERE TicketId IS NOT NULL;
END
GO

/* =============================================================================
   ErrorOccurrenceDetail - the heavy 1:1 payload
   ============================================================================= */
IF OBJECT_ID(N'erp_err.ErrorOccurrenceDetail', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.ErrorOccurrenceDetail
    (
        OccurrenceId        BIGINT          NOT NULL,
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
        CONSTRAINT PK_ErrorOccurrenceDetail PRIMARY KEY CLUSTERED (OccurrenceId),
        CONSTRAINT FK_OccurrenceDetail_Occurrence FOREIGN KEY (OccurrenceId)
            REFERENCES erp_err.ErrorOccurrence (OccurrenceId) ON DELETE CASCADE
    );
END
GO

/* =============================================================================
   Ticket
   ============================================================================= */
IF OBJECT_ID(N'erp_err.Ticket', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.Ticket
    (
        TicketId            BIGINT          IDENTITY(1,1) NOT NULL,
        TicketNumber        VARCHAR(24)     NOT NULL,      -- 'TKT-2026-00000317'

        -- The occurrence the user was looking at when they pressed Report.
        OccurrenceId        BIGINT          NULL,
        -- The problem.  Repeat reports of the same problem attach here.
        FingerprintId       BIGINT          NOT NULL,

        StatusId            TINYINT         NOT NULL,
        SeverityId          TINYINT         NOT NULL,
        QueueId             SMALLINT        NOT NULL,
        SlaPolicyId         SMALLINT        NULL,

        Title               NVARCHAR(400)   NOT NULL,
        -- What the user typed in the modal, if anything.
        UserDescription     NVARCHAR(MAX)   NULL,

        ReportedByUserId    NVARCHAR(128)   NULL,
        ReportedByUserName  NVARCHAR(200)   NULL,
        -- 'user' | 'auto_rule' | 'admin'
        CreatedVia          NVARCHAR(20)    NOT NULL CONSTRAINT DF_Ticket_CreatedVia DEFAULT (N'user'),
        AssignedToUserId    NVARCHAR(128)   NULL,
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

        CONSTRAINT PK_Ticket PRIMARY KEY CLUSTERED (TicketId),
        CONSTRAINT UQ_Ticket_Number UNIQUE (TicketNumber),
        CONSTRAINT FK_Ticket_Occurrence  FOREIGN KEY (OccurrenceId)  REFERENCES erp_err.ErrorOccurrence (OccurrenceId),
        CONSTRAINT FK_Ticket_Fingerprint FOREIGN KEY (FingerprintId) REFERENCES erp_err.ErrorFingerprint (FingerprintId),
        CONSTRAINT FK_Ticket_Status      FOREIGN KEY (StatusId)      REFERENCES erp_err.TicketStatus (StatusId),
        CONSTRAINT FK_Ticket_Severity    FOREIGN KEY (SeverityId)    REFERENCES erp_err.Severity (SeverityId),
        CONSTRAINT FK_Ticket_Queue       FOREIGN KEY (QueueId)       REFERENCES erp_err.TicketQueue (QueueId),
        CONSTRAINT FK_Ticket_Sla         FOREIGN KEY (SlaPolicyId)   REFERENCES erp_err.SlaPolicy (SlaPolicyId)
    );

    CREATE INDEX IX_Ticket_Status      ON erp_err.Ticket (StatusId, CreatedUtc DESC) INCLUDE (QueueId, SeverityId, AssignedToUserName);
    CREATE INDEX IX_Ticket_Queue       ON erp_err.Ticket (QueueId, StatusId, CreatedUtc DESC);
    CREATE INDEX IX_Ticket_Reporter    ON erp_err.Ticket (ReportedByUserName, CreatedUtc DESC);
    CREATE INDEX IX_Ticket_Assignee    ON erp_err.Ticket (AssignedToUserName, StatusId);
    CREATE INDEX IX_Ticket_Fingerprint ON erp_err.Ticket (FingerprintId, StatusId);
END
GO

/* FK from occurrence -> ticket added after Ticket exists (circular reference). */
IF OBJECT_ID(N'erp_err.Ticket', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Occurrence_Ticket')
    ALTER TABLE erp_err.ErrorOccurrence WITH CHECK
        ADD CONSTRAINT FK_Occurrence_Ticket FOREIGN KEY (TicketId) REFERENCES erp_err.Ticket (TicketId);
GO
IF OBJECT_ID(N'erp_err.Ticket', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Fingerprint_OpenTicket')
    ALTER TABLE erp_err.ErrorFingerprint WITH CHECK
        ADD CONSTRAINT FK_Fingerprint_OpenTicket FOREIGN KEY (OpenTicketId) REFERENCES erp_err.Ticket (TicketId);
GO

/* =============================================================================
   TicketStatusHistory - the audit trail the brief specified, verbatim
   ============================================================================= */
IF OBJECT_ID(N'erp_err.TicketStatusHistory', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.TicketStatusHistory
    (
        HistoryId           BIGINT          IDENTITY(1,1) NOT NULL,
        TicketId            BIGINT          NOT NULL,
        SequenceNo          INT             NOT NULL,      -- 1-based, gapless per ticket
        FromStatusId        TINYINT         NULL,          -- NULL on creation
        ToStatusId          TINYINT         NOT NULL,
        ChangedByUserId     NVARCHAR(128)   NULL,
        ChangedByUserName   NVARCHAR(200)   NULL,
        ChangedUtc          DATETIME2(3)    NOT NULL CONSTRAINT DF_TSH_ChangedUtc DEFAULT (SYSUTCDATETIME()),
        -- Minutes the ticket spent in FromStatusId before this change.  This is
        -- the column that answers "time spent in each status" without a window
        -- function over the whole history at report time.
        MinutesInFromStatus INT             NULL,
        Comments            NVARCHAR(MAX)   NULL,
        -- Visible to the end user, or internal-only?
        IsCustomerVisible   BIT             NOT NULL CONSTRAINT DF_TSH_Visible DEFAULT (1),
        CONSTRAINT PK_TicketStatusHistory PRIMARY KEY CLUSTERED (TicketId, SequenceNo),
        CONSTRAINT UQ_TicketStatusHistory_Id UNIQUE (HistoryId),
        CONSTRAINT FK_TSH_Ticket FOREIGN KEY (TicketId) REFERENCES erp_err.Ticket (TicketId) ON DELETE CASCADE,
        CONSTRAINT FK_TSH_From   FOREIGN KEY (FromStatusId) REFERENCES erp_err.TicketStatus (StatusId),
        CONSTRAINT FK_TSH_To     FOREIGN KEY (ToStatusId)   REFERENCES erp_err.TicketStatus (StatusId)
    );
    CREATE INDEX IX_TSH_ChangedUtc ON erp_err.TicketStatusHistory (ChangedUtc DESC);
END
GO

/* Free-text conversation on a ticket, separate from status changes so the
   history stays a clean state machine log.                                    */
IF OBJECT_ID(N'erp_err.TicketComment', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.TicketComment
    (
        CommentId           BIGINT          IDENTITY(1,1) NOT NULL,
        TicketId            BIGINT          NOT NULL,
        AuthorUserId        NVARCHAR(128)   NULL,
        AuthorUserName      NVARCHAR(200)   NULL,
        -- 'reporter' | 'support' | 'system'
        AuthorRole          NVARCHAR(20)    NOT NULL CONSTRAINT DF_TC_Role DEFAULT (N'support'),
        CommentText         NVARCHAR(MAX)   NOT NULL,
        IsCustomerVisible   BIT             NOT NULL CONSTRAINT DF_TC_Visible DEFAULT (1),
        CreatedUtc          DATETIME2(3)    NOT NULL CONSTRAINT DF_TC_CreatedUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_TicketComment PRIMARY KEY CLUSTERED (CommentId),
        CONSTRAINT FK_TC_Ticket FOREIGN KEY (TicketId) REFERENCES erp_err.Ticket (TicketId) ON DELETE CASCADE
    );
    CREATE INDEX IX_TC_Ticket ON erp_err.TicketComment (TicketId, CreatedUtc);
END
GO

/* Links every additional occurrence that arrived while a ticket was open, so
   "this ticket represents 812 failures across 43 users" is a query, not a
   guess.                                                                       */
IF OBJECT_ID(N'erp_err.TicketOccurrenceLink', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.TicketOccurrenceLink
    (
        TicketId        BIGINT          NOT NULL,
        OccurrenceId    BIGINT          NOT NULL,
        LinkedUtc       DATETIME2(3)    NOT NULL CONSTRAINT DF_TOL_LinkedUtc DEFAULT (SYSUTCDATETIME()),
        -- 'primary' (the one the user reported) | 'deduplicated' | 'manual'
        LinkReason      NVARCHAR(20)    NOT NULL CONSTRAINT DF_TOL_Reason DEFAULT (N'deduplicated'),
        CONSTRAINT PK_TicketOccurrenceLink PRIMARY KEY CLUSTERED (TicketId, OccurrenceId),
        CONSTRAINT FK_TOL_Ticket     FOREIGN KEY (TicketId)     REFERENCES erp_err.Ticket (TicketId) ON DELETE CASCADE,
        CONSTRAINT FK_TOL_Occurrence FOREIGN KEY (OccurrenceId) REFERENCES erp_err.ErrorOccurrence (OccurrenceId)
    );
    CREATE INDEX IX_TOL_Occurrence ON erp_err.TicketOccurrenceLink (OccurrenceId);
END
GO

/* =============================================================================
   Framework self-audit
   -----------------------------------------------------------------------------
   Who changed a configuration row, and when.  Kept deliberately generic.
   ============================================================================= */
IF OBJECT_ID(N'erp_err.ConfigAudit', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.ConfigAudit
    (
        AuditId         BIGINT          IDENTITY(1,1) NOT NULL,
        TableName       NVARCHAR(128)   NOT NULL,
        KeyValue        NVARCHAR(200)   NOT NULL,
        Operation       VARCHAR(10)     NOT NULL,     -- INSERT | UPDATE | DELETE
        OldValuesJson   NVARCHAR(MAX)   NULL,
        NewValuesJson   NVARCHAR(MAX)   NULL,
        ChangedByUserName NVARCHAR(200) NULL,
        ChangedUtc      DATETIME2(3)    NOT NULL CONSTRAINT DF_ConfigAudit_ChangedUtc DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_ConfigAudit PRIMARY KEY CLUSTERED (AuditId)
    );
    CREATE INDEX IX_ConfigAudit_Table ON erp_err.ConfigAudit (TableName, ChangedUtc DESC);
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
IF OBJECT_ID(N'erp_err.DeadLetter', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.DeadLetter
    (
        DeadLetterId    BIGINT          IDENTITY(1,1) NOT NULL,
        ReceivedUtc     DATETIME2(3)    NOT NULL CONSTRAINT DF_DeadLetter_Received DEFAULT (SYSUTCDATETIME()),
        Source          NVARCHAR(60)    NULL,          -- 'angular' | 'webapi2' | 'aspnetcore' | 'sql'
        RawEnvelopeJson NVARCHAR(MAX)   NULL,
        FailureReason   NVARCHAR(MAX)   NULL,
        CONSTRAINT PK_DeadLetter PRIMARY KEY CLUSTERED (DeadLetterId)
    );
END
GO

MERGE erp_err.SchemaVersion AS t
USING (SELECT N'002_core_tables.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion) VALUES (s.ScriptName, N'1.0.0');
GO
