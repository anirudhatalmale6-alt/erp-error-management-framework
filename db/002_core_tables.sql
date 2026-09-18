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
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_ReferenceCounter_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
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
                INSERT ERM.ERM_ReferenceCounter (RefType, RefDate, LastValue)
                VALUES (@RefType, @Today, 1);

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
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_ErrorFingerprint_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
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

        /* ---- who ---- */
        UserID              NVARCHAR(128)   NULL,
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
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_ErrorOccurrence_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
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
        INCLUDE (ERM_ErrorFingerprintID, SeverityID, LayerID, ErpModule, UserName, ERM_TicketID);
    CREATE INDEX IX_Occurrence_Fingerprint  ON ERM.ERM_ErrorOccurrence (ERM_ErrorFingerprintID, OccurredUtc DESC);
    CREATE INDEX IX_Occurrence_Correlation  ON ERM.ERM_ErrorOccurrence (CorrelationID, OccurredUtc);
    CREATE INDEX IX_Occurrence_User         ON ERM.ERM_ErrorOccurrence (UserName, OccurredUtc DESC);
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
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_ErrorOccurrenceDetail_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
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

        ReportedByUserID    NVARCHAR(128)   NULL,
        ReportedByUserName  NVARCHAR(200)   NULL,
        -- 'user' | 'auto_rule' | 'admin'
        CreatedVia          NVARCHAR(20)    NOT NULL CONSTRAINT DF_Ticket_CreatedVia DEFAULT (N'user'),
        AssignedToUserID    NVARCHAR(128)   NULL,
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
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_Ticket_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
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

    CREATE INDEX IX_Ticket_Status      ON ERM.ERM_Ticket (StatusID, CreatedUtc DESC) INCLUDE (ERM_TicketQueueID, SeverityID, AssignedToUserName);
    CREATE INDEX IX_Ticket_Queue       ON ERM.ERM_Ticket (ERM_TicketQueueID, StatusID, CreatedUtc DESC);
    CREATE INDEX IX_Ticket_Reporter    ON ERM.ERM_Ticket (ReportedByUserName, CreatedUtc DESC);
    CREATE INDEX IX_Ticket_Assignee    ON ERM.ERM_Ticket (AssignedToUserName, StatusID);
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
        ChangedByUserID     NVARCHAR(128)   NULL,
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
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_TicketStatusHistory_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
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
        AuthorUserID        NVARCHAR(128)   NULL,
        AuthorUserName      NVARCHAR(200)   NULL,
        -- 'reporter' | 'support' | 'system'
        AuthorRole          NVARCHAR(20)    NOT NULL CONSTRAINT DF_TC_Role DEFAULT (N'support'),
        CommentText         NVARCHAR(MAX)   NOT NULL,
        IsCustomerVisible   BIT             NOT NULL CONSTRAINT DF_TC_Visible DEFAULT (1),
        CreatedUtc          DATETIME2(3)    NOT NULL CONSTRAINT DF_TC_CreatedUtc DEFAULT (SYSUTCDATETIME()),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_TicketComment_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_TicketComment_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_TicketComment_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
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
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_TicketOccurrenceLink_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
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
        ChangedByUserName NVARCHAR(200) NULL,
        ChangedUtc      DATETIME2(3)    NOT NULL CONSTRAINT DF_ConfigAudit_ChangedUtc DEFAULT (SYSUTCDATETIME()),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_ConfigAudit_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_ConfigAudit_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_ConfigAudit_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
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
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_DeadLetter_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
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
    INSERT (ScriptName, FrameworkVersion) VALUES (s.ScriptName, N'1.0.0');
GO
