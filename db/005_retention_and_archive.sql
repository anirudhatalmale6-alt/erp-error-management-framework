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
