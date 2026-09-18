/* =============================================================================
   ERP Error Management Framework
   Script 008 - OPTIONAL: catching errors a stored procedure swallowed

   ┌───────────────────────────────────────────────────────────────────────────┐
   │ THIS SCRIPT IS OPTIONAL AND IS NOT PART OF THE DEFAULT INSTALL.          │
   │ Scripts 001-007 are the framework.  This one is an add-on with a real    │
   │ (small) standing cost on the SQL Server instance, so it is a decision    │
   │ for you rather than a default I make on your behalf.                     │
   └───────────────────────────────────────────────────────────────────────────┘

   THE PROBLEM
   -----------
   Everything else in this framework captures database errors by reading the
   SqlException that reaches .NET.  That works because an unhandled error inside
   a procedure propagates to the client.

   It does not work when the procedure handles the error itself:

       BEGIN TRY
           EXEC dbo.usp_PostJournalLine @LineId;
       END TRY
       BEGIN CATCH
           SET @Result = -1;              -- error absorbed here
           -- no THROW, no RAISERROR
       END CATCH
       RETURN @Result;                    -- caller sees -1, not an exception

   The error genuinely happened - SQL Server raised it - but nothing outside the
   procedure can observe it.  No client-side mechanism can, either: from .NET's
   point of view the call succeeded and returned -1.  This is the database
   equivalent of the front-end "handled failure" problem, and it has the same
   shape: the only signal is inside code that decided not to signal.

   WHAT THIS SCRIPT DOES
   ---------------------
   Creates an Extended Events session on `error_reported`, which fires when SQL
   Server RAISES the error - before any TRY/CATCH gets the chance to absorb it.
   A scheduled procedure then reads the session's ring buffer and writes what it
   finds into ERM as database-layer occurrences.

   WHAT IT COSTS, HONESTLY
   -----------------------
   * A permanent XE session on the instance.  `error_reported` is a low-cost
     event, but it is not free, and on a busy instance it is not silent either.
   * It fires for EVERY error at or above the configured severity, including
     ones that were handled correctly and deliberately.  A procedure that uses
     TRY/CATCH as intended control flow will generate rows here.  Expect noise
     on the first day and expect to tune the filter.
   * Ring buffer, not a file target: bounded memory, and events are LOST if the
     collector does not run often enough.  That is the correct trade for a
     diagnostic aid - it must never be able to fill a disk on the ERP's server.
   * INSTANCE-WIDE permissions to create it (ALTER ANY EVENT SESSION, a
     server-level right).  That is a bigger ask than anything in 001-007, all
     of which are database-scoped.  Your DBA will, correctly, want to know why.
   * Errors raised inside a procedure carry NO reliable user or correlation
     context - XE sees the session, not the ERP request.  So these rows join to
     the rest of the data by TIME and SPID, which is weaker than the correlation
     id used everywhere else.  Treat them as a trend signal, not as a trail.

   MY RECOMMENDATION
   -----------------
   Do not install this on day one.  Run 001-007, get a week of real data, and
   see whether you actually have a blind spot worth this cost.  In most ERPs the
   swallowed errors turn out to be a handful of known TRY/CATCH blocks that are
   cheaper to instrument directly - and script 009 below shows that alternative,
   which needs no server-level rights at all.

   Requires: SQL Server 2012+ for the XE session, 2016+ for the rest.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* --------------------------------------------------------- landing table -- */
IF OBJECT_ID(N'ERM.ERM_SwallowedSqlError', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_SwallowedSqlError
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_SwallowedSqlError_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_SwallowedSqlError_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_SwallowedSqlError_AppNo DEFAULT (1),
        ERM_SwallowedSqlErrorID     BIGINT          IDENTITY(1,1) NOT NULL,
        /* The timestamp from the event itself, not from the collector. */
        RaisedUtc       DATETIME2(3)    NOT NULL,
        CollectedUtc    DATETIME2(3)    NOT NULL CONSTRAINT DF_Swallowed_Collected DEFAULT (SYSUTCDATETIME()),
        ErrorNumber     INT             NULL,
        ErrorSeverity   TINYINT         NULL,
        ErrorState      TINYINT         NULL,
        Message         NVARCHAR(2000)  NULL,
        DatabaseName    NVARCHAR(128)   NULL,
        SessionID       INT             NULL,   -- SPID
        ClientHostName  NVARCHAR(128)   NULL,
        ClientAppName   NVARCHAR(256)   NULL,
        SqlText         NVARCHAR(MAX)   NULL,
        /* Set once the row has been promoted into ErrorOccurrence, so the
           collector is idempotent and can be re-run safely. */
        PromotedOccurrenceID BIGINT     NULL,
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_SwallowedSqlError_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_SwallowedSqlError_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_SwallowedSqlError_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_SwallowedSqlError_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_SwallowedSqlError PRIMARY KEY CLUSTERED (ERM_SwallowedSqlErrorID)
    );

    CREATE INDEX IX_Swallowed_RaisedUtc ON ERM.ERM_SwallowedSqlError (RaisedUtc DESC);

    /* Dedupe key for the collector: the same event read twice from an
       overlapping ring-buffer window must not become two rows. */
    CREATE UNIQUE INDEX UX_Swallowed_Event
        ON ERM.ERM_SwallowedSqlError (RaisedUtc, SessionID, ErrorNumber)
        WHERE ErrorNumber IS NOT NULL;
END
GO

/* ------------------------------------------------------------ XE session -- */
/*  Run this part with a login holding ALTER ANY EVENT SESSION.

    The filter is the part to tune.  As shipped:
      severity >= 16   - excludes informational and most deliberate RAISERROR
      error_number NOT IN (...)  - excludes the errors that are pure noise
      database_id      - SET THIS to your ERP database, or the session collects
                         errors from every database on the instance including
                         msdb's own housekeeping.
*/
IF NOT EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'ERM_swallowed')
BEGIN
    DECLARE @dbid INT = DB_ID();   -- the database this script is run in
    DECLARE @sql NVARCHAR(MAX) = N'
    CREATE EVENT SESSION [ERM_swallowed] ON SERVER
    ADD EVENT sqlserver.error_reported
    (
        ACTION
        (
            sqlserver.session_id,
            sqlserver.database_name,
            sqlserver.client_hostname,
            sqlserver.client_app_name,
            sqlserver.sql_text
        )
        WHERE
        (
                severity >= 16
            AND database_id = ' + CONVERT(NVARCHAR(20), @dbid) + N'
            /* 3621 = "the statement has been terminated", always paired with
                       the real error, so it doubles every row.
               1205 = deadlock victim - already captured properly via
                       SqlException, with the procedure name attached.
               8134 = divide by zero. Keep if you want it; it is usually a
                       data problem a procedure handles on purpose.
               and the login/connection numbers, which are connection events
               rather than statement errors. */
            AND error_number NOT IN (3621, 1205, 18456, 4060, 17142)
        )
    )
    ADD TARGET package0.ring_buffer
    (
        /* Bounded on purpose. If the collector stops, events are lost rather
           than accumulating - a diagnostic aid must not be able to pressure
           memory on the ERP''s own server. */
        SET max_memory = 4096,          -- KB
            max_events_limit = 1000
    )
    WITH
    (
        MAX_DISPATCH_LATENCY = 30 SECONDS,
        /* Allow single event loss under pressure. The alternative,
           NO_EVENT_LOSS, can stall the SESSION THAT RAISED THE ERROR - i.e.
           an ERP user transaction - which is completely unacceptable for
           something whose only job is to observe. */
        EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
        STARTUP_STATE = ON
    );';

    EXEC sp_executesql @sql;
    PRINT N'Created event session [ERM_swallowed] filtered to database_id ' + CONVERT(NVARCHAR(20), @dbid);
END
ELSE
    PRINT N'Event session [ERM_swallowed] already exists - left untouched.';
GO

IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'ERM_swallowed')
   AND NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'ERM_swallowed')
BEGIN
    ALTER EVENT SESSION [ERM_swallowed] ON SERVER STATE = START;
    PRINT N'Event session started.';
END
GO

/* =============================================================================
   usp_Swallowed_Collect
   -----------------------------------------------------------------------------
   Shreds the ring buffer into ERM.ERM_SwallowedSqlError, then optionally
   promotes the rows into ErrorOccurrence so they appear in the normal console
   alongside everything else.

   Schedule every 1-5 minutes.  Less often than MAX_DISPATCH_LATENCY plus the
   ring-buffer capacity and you WILL lose events - which is a documented
   trade-off of this approach, not a bug.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Swallowed_Collect
(
    @PromoteToOccurrence BIT = 1,
    /* Only promote errors seen at least this many times in the window, so a
       single deliberate TRY/CATCH does not create a ticket-able problem. */
    @PromoteMinOccurrences INT = 3,
    @WindowMinutes INT = 60
)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'ERM_swallowed')
        BEGIN
            /* Session not running: say so rather than silently collecting
               nothing for six months. */
            INSERT ERM.ERM_DeadLetter (Source, FailureReason)
            VALUES (N'xevents', N'Event session [ERM_swallowed] is not running.');
            RETURN;
        END

        DECLARE @xml XML =
        (
            SELECT CONVERT(XML, t.target_data)
            FROM sys.dm_xe_sessions s
            JOIN sys.dm_xe_session_targets t ON t.event_session_address = s.address
            WHERE s.name = N'ERM_swallowed' AND t.target_name = N'ring_buffer'
        );

        IF @xml IS NULL RETURN;

        ;WITH events AS
        (
            SELECT
                /* XE timestamps are UTC already. */
                x.value('@timestamp', 'DATETIME2(3)')                                   AS RaisedUtc,
                x.value('(data[@name="error_number"]/value)[1]', 'INT')                 AS ErrorNumber,
                x.value('(data[@name="severity"]/value)[1]', 'TINYINT')                 AS ErrorSeverity,
                x.value('(data[@name="state"]/value)[1]', 'TINYINT')                    AS ErrorState,
                x.value('(data[@name="message"]/value)[1]', 'NVARCHAR(2000)')           AS Message,
                x.value('(action[@name="database_name"]/value)[1]', 'NVARCHAR(128)')    AS DatabaseName,
                x.value('(action[@name="session_id"]/value)[1]', 'INT')                 AS SessionID,
                x.value('(action[@name="client_hostname"]/value)[1]', 'NVARCHAR(128)')  AS ClientHostName,
                x.value('(action[@name="client_app_name"]/value)[1]', 'NVARCHAR(256)')  AS ClientAppName,
                x.value('(action[@name="sql_text"]/value)[1]', 'NVARCHAR(MAX)')         AS SqlText
            FROM @xml.nodes('//RingBufferTarget/event') AS e(x)
        )
        INSERT ERM.ERM_SwallowedSqlError
            (RaisedUtc, ErrorNumber, ErrorSeverity, ErrorState, Message,
             DatabaseName, SessionID, ClientHostName, ClientAppName, SqlText)
        SELECT e.RaisedUtc, e.ErrorNumber, e.ErrorSeverity, e.ErrorState, e.Message,
               e.DatabaseName, e.SessionID, e.ClientHostName, e.ClientAppName, e.SqlText
        FROM events e
        WHERE e.ErrorNumber IS NOT NULL
          /* The ring buffer is re-read on every run, so the same event is seen
             repeatedly until it ages out.  This is the dedupe. */
          AND NOT EXISTS (
                SELECT 1 FROM ERM.ERM_SwallowedSqlError x
                WHERE x.RaisedUtc = e.RaisedUtc
                  AND x.SessionID = e.SessionID
                  AND x.ErrorNumber = e.ErrorNumber);

        IF @PromoteToOccurrence = 0 RETURN;

        /* ---- promote recurring ones into the normal occurrence stream ---- */
        DECLARE @Cutoff DATETIME2(3) = DATEADD(MINUTE, -@WindowMinutes, SYSUTCDATETIME());

        DECLARE @promote TABLE
        (
            ERM_SwallowedSqlErrorID BIGINT, RaisedUtc DATETIME2(3), ErrorNumber INT,
            ErrorSeverity TINYINT, ErrorState TINYINT, Message NVARCHAR(2000),
            DatabaseName NVARCHAR(128), SqlText NVARCHAR(MAX), ObjectName NVARCHAR(256)
        );

        INSERT @promote
        SELECT s.ERM_SwallowedSqlErrorID, s.RaisedUtc, s.ErrorNumber, s.ErrorSeverity, s.ErrorState,
               s.Message, s.DatabaseName, s.SqlText,
               /* Best effort at a procedure name from the captured statement.
                  XE gives the statement, not the enclosing object, so this is a
                  heuristic and is left NULL when it cannot be determined -
                  a wrong object name would fingerprint two faults together. */
               CASE WHEN s.SqlText LIKE N'%[Pp][Rr][Oo][Cc]%' THEN NULL ELSE NULL END
        FROM ERM.ERM_SwallowedSqlError s
        WHERE s.PromotedOccurrenceID IS NULL
          AND s.RaisedUtc >= @Cutoff
          AND @PromoteMinOccurrences <= (
                SELECT COUNT_BIG(*) FROM ERM.ERM_SwallowedSqlError c
                WHERE c.ErrorNumber = s.ErrorNumber AND c.RaisedUtc >= @Cutoff);

        DECLARE @ERM_SwallowedSqlErrorID BIGINT, @RaisedUtc DATETIME2(3), @ErrorNumber INT,
                @ErrorSeverity TINYINT, @ErrorState TINYINT, @Message NVARCHAR(2000),
                @DatabaseName NVARCHAR(128), @SqlText NVARCHAR(MAX), @ObjectName NVARCHAR(256);

        DECLARE promote_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT ERM_SwallowedSqlErrorID, RaisedUtc, ErrorNumber, ErrorSeverity, ErrorState,
                   Message, DatabaseName, SqlText, ObjectName
            FROM @promote;

        OPEN promote_cur;
        FETCH NEXT FROM promote_cur INTO @ERM_SwallowedSqlErrorID, @RaisedUtc, @ErrorNumber,
            @ErrorSeverity, @ErrorState, @Message, @DatabaseName, @SqlText, @ObjectName;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            /* Build the same envelope shape the application sends, so these
               rows are indistinguishable from any other database-layer
               occurrence in the console and in the recurring-problem report.

               The fingerprint is computed HERE rather than in the application,
               so it must follow the same rules: normalise the volatile parts of
               the message out before hashing. */
            DECLARE @Normalised NVARCHAR(2000) = @Message;
            /* Numbers -> {n}: object ids, row counts, SPIDs. */
            DECLARE @i INT = 0;
            WHILE @i < 10
            BEGIN
                SET @Normalised = REPLACE(@Normalised, CONVERT(NVARCHAR(1), @i), N'#');
                SET @i += 1;
            END
            /* Collapse runs of the digit placeholder. */
            WHILE CHARINDEX(N'##', @Normalised) > 0
                SET @Normalised = REPLACE(@Normalised, N'##', N'#');

            DECLARE @Signature NVARCHAR(1000) =
                N'database|sql_procedure|SwallowedSqlError|'
                + ISNULL(@Normalised, N'') + N'|'
                + CONVERT(NVARCHAR(20), ISNULL(@ErrorNumber, 0)) + N'|'
                + ISNULL(@ObjectName, N'');

            /* HASHBYTES gives the same SHA-256 the C# and TypeScript sides use,
               over the same UTF-8-equivalent bytes.  CONVERT(...,2) renders it
               as lower-case hex without the 0x prefix, matching CHAR(64). */
            DECLARE @Hash CHAR(64) =
                LOWER(CONVERT(CHAR(64), HASHBYTES('SHA2_256', @Signature), 2));

            DECLARE @Envelope NVARCHAR(MAX) =
            (
                SELECT
                    @Hash                       AS fingerprintHash,
                    @Signature                  AS signatureText,
                    N'database'                 AS layer,
                    N'sql_procedure'            AS category,
                    CASE WHEN @ErrorSeverity >= 17 THEN N'critical' ELSE N'medium' END AS severity,
                    N'SwallowedSqlError'        AS exceptionType,
                    @Message                    AS message,
                    @Normalised                 AS normalizedMessage,
                    CONVERT(NVARCHAR(40), @RaisedUtc, 127) AS occurredUtc,
                    N'SQL Server'               AS environment,
                    @ErrorNumber                AS [sql.number],
                    @ErrorSeverity              AS [sql.severity],
                    @ErrorState                 AS [sql.state],
                    @ObjectName                 AS [sql.objectName],
                    @DatabaseName               AS [sql.databaseName],
                    LEFT(ISNULL(@SqlText, N''), 4000) AS [sql.statement]
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
            );

            DECLARE @results TABLE
            (
                ErrorReference VARCHAR(30), ERM_ErrorOccurrenceID BIGINT, ERM_ErrorFingerprintID BIGINT,
                ShouldNotifyUser BIT, AutoTicketNumber VARCHAR(30), IsKnownIssue BIT
            );
            DELETE @results;

            INSERT @results
            EXEC ERM.usp_Error_Capture @EnvelopeJson = @Envelope, @Source = N'sql-xevents';

            UPDATE ERM.ERM_SwallowedSqlError
               SET PromotedOccurrenceID = (SELECT TOP 1 ERM_ErrorOccurrenceID FROM @results)
             WHERE ERM_SwallowedSqlErrorID = @ERM_SwallowedSqlErrorID;

            FETCH NEXT FROM promote_cur INTO @ERM_SwallowedSqlErrorID, @RaisedUtc, @ErrorNumber,
                @ErrorSeverity, @ErrorState, @Message, @DatabaseName, @SqlText, @ObjectName;
        END

        CLOSE promote_cur;
        DEALLOCATE promote_cur;
    END TRY
    BEGIN CATCH
        /* Same rule as everywhere else: a collector failure is recorded, never
           raised.  This runs on a schedule against a production instance. */
        BEGIN TRY
            INSERT ERM.ERM_DeadLetter (Source, FailureReason)
            VALUES (N'xevents', CONCAT(N'usp_Swallowed_Collect failed: Msg ', ERROR_NUMBER(),
                                       N', Line ', ERROR_LINE(), N': ', ERROR_MESSAGE()));
        END TRY
        BEGIN CATCH
        END CATCH
    END CATCH
END
GO

/* -----------------------------------------------------------------------------
   Retention for the landing table - it is the noisiest thing in the schema.
   ----------------------------------------------------------------------------- */
MERGE ERM.ERM_RetentionPolicy AS t
USING (SELECT N'swallowed_sql' AS DataSet, 14 AS ArchiveAfterDays, 30 AS PurgeAfterDays, 5000 AS BatchSize) AS s
    ON t.DataSet = s.DataSet
WHEN NOT MATCHED THEN
    INSERT (DataSet, ArchiveAfterDays, PurgeAfterDays, BatchSize)
    VALUES (s.DataSet, s.ArchiveAfterDays, s.PurgeAfterDays, s.BatchSize);
GO

/* -----------------------------------------------------------------------------
   TO REMOVE THIS ENTIRELY
   -----------------------------------------------------------------------------
       DROP EVENT SESSION [ERM_swallowed] ON SERVER;
       DROP PROCEDURE ERM.usp_Swallowed_Collect;
       DROP TABLE ERM.ERM_SwallowedSqlError;
       DELETE ERM.ERM_RetentionPolicy WHERE DataSet = N'swallowed_sql';

   Nothing in 001-007 depends on any of it.
   ----------------------------------------------------------------------------- */

/* -----------------------------------------------------------------------------
   SQL Agent job
   -----------------------------------------------------------------------------
       EXEC msdb.dbo.sp_add_job @job_name = N'ERP Error Mgmt - Collect swallowed SQL errors';
       EXEC msdb.dbo.sp_add_jobstep
            @job_name = N'ERP Error Mgmt - Collect swallowed SQL errors',
            @step_name = N'Collect', @subsystem = N'TSQL',
            @database_name = N'YourErpDb',
            @command = N'EXEC ERM.usp_Swallowed_Collect;';
       -- every 2 minutes
       EXEC msdb.dbo.sp_add_jobschedule
            @job_name = N'ERP Error Mgmt - Collect swallowed SQL errors',
            @name = N'Every 2 minutes', @freq_type = 4, @freq_interval = 1,
            @freq_subday_type = 4, @freq_subday_interval = 2;
       EXEC msdb.dbo.sp_add_jobserver @job_name = N'ERP Error Mgmt - Collect swallowed SQL errors';
   ----------------------------------------------------------------------------- */

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'008_optional_swallowed_sql_errors.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion) VALUES (s.ScriptName, N'1.1.0-optional');
GO
