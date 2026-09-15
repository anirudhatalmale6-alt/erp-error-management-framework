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
IF OBJECT_ID(N'erp_err.ErrorOccurrence_Archive', N'U') IS NULL
BEGIN
    SELECT TOP 0 * INTO erp_err.ErrorOccurrence_Archive FROM erp_err.ErrorOccurrence;
    ALTER TABLE erp_err.ErrorOccurrence_Archive ADD ArchivedUtc DATETIME2(3) NOT NULL
        CONSTRAINT DF_OccArchive_ArchivedUtc DEFAULT (SYSUTCDATETIME());
    CREATE CLUSTERED INDEX CX_OccArchive_OccurredUtc ON erp_err.ErrorOccurrence_Archive (OccurredUtc);
    CREATE NONCLUSTERED INDEX IX_OccArchive_Reference ON erp_err.ErrorOccurrence_Archive (ErrorReference);
END
GO

IF OBJECT_ID(N'erp_err.ErrorOccurrenceDetail_Archive', N'U') IS NULL
BEGIN
    SELECT TOP 0 * INTO erp_err.ErrorOccurrenceDetail_Archive FROM erp_err.ErrorOccurrenceDetail;
    ALTER TABLE erp_err.ErrorOccurrenceDetail_Archive ADD ArchivedUtc DATETIME2(3) NOT NULL
        CONSTRAINT DF_DetailArchive_ArchivedUtc DEFAULT (SYSUTCDATETIME());
    CREATE CLUSTERED INDEX CX_DetailArchive_OccurrenceId ON erp_err.ErrorOccurrenceDetail_Archive (OccurrenceId);
END
GO

IF OBJECT_ID(N'erp_err.Ticket_Archive', N'U') IS NULL
BEGIN
    SELECT TOP 0 * INTO erp_err.Ticket_Archive FROM erp_err.Ticket;
    ALTER TABLE erp_err.Ticket_Archive ADD ArchivedUtc DATETIME2(3) NOT NULL
        CONSTRAINT DF_TicketArchive_ArchivedUtc DEFAULT (SYSUTCDATETIME());
    CREATE CLUSTERED INDEX CX_TicketArchive_ClosedUtc ON erp_err.Ticket_Archive (ClosedUtc);
    CREATE NONCLUSTERED INDEX IX_TicketArchive_Number ON erp_err.Ticket_Archive (TicketNumber);
END
GO

IF OBJECT_ID(N'erp_err.TicketStatusHistory_Archive', N'U') IS NULL
BEGIN
    SELECT TOP 0 * INTO erp_err.TicketStatusHistory_Archive FROM erp_err.TicketStatusHistory;
    ALTER TABLE erp_err.TicketStatusHistory_Archive ADD ArchivedUtc DATETIME2(3) NOT NULL
        CONSTRAINT DF_TSHArchive_ArchivedUtc DEFAULT (SYSUTCDATETIME());
    CREATE CLUSTERED INDEX CX_TSHArchive_Ticket ON erp_err.TicketStatusHistory_Archive (TicketId, SequenceNo);
END
GO

IF OBJECT_ID(N'erp_err.TicketComment_Archive', N'U') IS NULL
BEGIN
    SELECT TOP 0 * INTO erp_err.TicketComment_Archive FROM erp_err.TicketComment;
    ALTER TABLE erp_err.TicketComment_Archive ADD ArchivedUtc DATETIME2(3) NOT NULL
        CONSTRAINT DF_TCArchive_ArchivedUtc DEFAULT (SYSUTCDATETIME());
    CREATE CLUSTERED INDEX CX_TCArchive_Ticket ON erp_err.TicketComment_Archive (TicketId, CommentId);
END
GO

/* ------------------------------------------------------------- run log --- */
IF OBJECT_ID(N'erp_err.RetentionRunLog', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.RetentionRunLog
    (
        RunId           BIGINT          IDENTITY(1,1) NOT NULL,
        StartedUtc      DATETIME2(3)    NOT NULL CONSTRAINT DF_RetentionRun_Started DEFAULT (SYSUTCDATETIME()),
        FinishedUtc     DATETIME2(3)    NULL,
        DataSet         NVARCHAR(40)    NOT NULL,
        RowsArchived    BIGINT          NOT NULL CONSTRAINT DF_RetentionRun_Archived DEFAULT (0),
        RowsPurged      BIGINT          NOT NULL CONSTRAINT DF_RetentionRun_Purged   DEFAULT (0),
        Succeeded       BIT             NOT NULL CONSTRAINT DF_RetentionRun_Succeeded DEFAULT (0),
        ErrorMessage    NVARCHAR(MAX)   NULL,
        CONSTRAINT PK_RetentionRunLog PRIMARY KEY CLUSTERED (RunId)
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
CREATE OR ALTER PROCEDURE erp_err.usp_Retention_Apply
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
    FROM erp_err.RetentionPolicy
    WHERE IsActive = 1 AND (@DataSet IS NULL OR DataSet = @DataSet);

    DECLARE @ds NVARCHAR(40), @archDays INT, @purgeDays INT, @batch INT;
    DECLARE @cutoff DATETIME2(3), @purgeCutoff DATETIME2(3);
    DECLARE @rows INT, @totalArchived BIGINT, @totalPurged BIGINT, @batches INT, @RunId BIGINT;

    /* Declared here, not inside the loops: T-SQL DECLARE is batch-scoped, so a
       DECLARE that executes a second time raises "variable already declared". */
    DECLARE @moving  TABLE (OccurrenceId BIGINT PRIMARY KEY);
    DECLARE @movingT TABLE (TicketId     BIGINT PRIMARY KEY);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT DataSet, ArchiveAfterDays, PurgeAfterDays, BatchSize FROM @policies;
    OPEN cur;
    FETCH NEXT FROM cur INTO @ds, @archDays, @purgeDays, @batch;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @totalArchived = 0; SET @totalPurged = 0; SET @batches = 0;
        SET @cutoff      = CASE WHEN @archDays  > 0 THEN DATEADD(DAY, -@archDays,  @Now) END;
        SET @purgeCutoff = CASE WHEN @purgeDays > 0 THEN DATEADD(DAY, -@purgeDays, @Now) END;

        INSERT erp_err.RetentionRunLog (DataSet) VALUES (@ds);
        SET @RunId = SCOPE_IDENTITY();

        BEGIN TRY
            /* ============================ occurrence_detail ================ */
            IF @ds = N'occurrence_detail' AND @cutoff IS NOT NULL
            BEGIN
                IF @WhatIf = 1
                BEGIN
                    SELECT @ds AS DataSet, COUNT_BIG(*) AS RowsThatWouldArchive
                    FROM erp_err.ErrorOccurrenceDetail d
                    JOIN erp_err.ErrorOccurrence o ON o.OccurrenceId = d.OccurrenceId
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
                            OUTPUT deleted.OccurrenceId, deleted.StackTrace, deleted.InnerExceptionChain,
                                   deleted.RequestPayloadJson, deleted.ResponsePayloadJson,
                                   deleted.ValidationErrorsJson, deleted.BreadcrumbsJson,
                                   deleted.CustomDataJson, deleted.SqlStatementText, @Now
                            INTO erp_err.ErrorOccurrenceDetail_Archive
                                 (OccurrenceId, StackTrace, InnerExceptionChain, RequestPayloadJson,
                                  ResponsePayloadJson, ValidationErrorsJson, BreadcrumbsJson,
                                  CustomDataJson, SqlStatementText, ArchivedUtc)
                            FROM erp_err.ErrorOccurrenceDetail d
                            WHERE EXISTS (SELECT 1 FROM erp_err.ErrorOccurrence o
                                          WHERE o.OccurrenceId = d.OccurrenceId AND o.OccurredUtc < @cutoff);
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
                        DELETE TOP (@batch) FROM erp_err.ErrorOccurrenceDetail_Archive
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
                    FROM erp_err.ErrorOccurrence o
                    WHERE o.OccurredUtc < @cutoff AND o.TicketId IS NULL;
                END
                ELSE
                BEGIN
                    SET @rows = 1;
                    WHILE @rows > 0 AND @batches < @MaxBatches
                    BEGIN
                        BEGIN TRANSACTION;
                            DELETE @moving;

                            INSERT @moving (OccurrenceId)
                            SELECT TOP (@batch) o.OccurrenceId
                            FROM erp_err.ErrorOccurrence o
                            WHERE o.OccurredUtc < @cutoff
                              /* An occurrence attached to a ticket is evidence.
                                 It ages out with its ticket, not on its own. */
                              AND o.TicketId IS NULL
                              /* Never orphan a child that is still hot. */
                              AND NOT EXISTS (SELECT 1 FROM erp_err.ErrorOccurrence ch
                                              WHERE ch.ParentOccurrenceId = o.OccurrenceId)
                            ORDER BY o.OccurredUtc;

                            SET @rows = @@ROWCOUNT;

                            IF @rows > 0
                            BEGIN
                                DELETE d FROM erp_err.ErrorOccurrenceDetail d
                                JOIN @moving m ON m.OccurrenceId = d.OccurrenceId;

                                DELETE li FROM erp_err.TicketOccurrenceLink li
                                JOIN @moving m ON m.OccurrenceId = li.OccurrenceId;

                                INSERT erp_err.ErrorOccurrence_Archive
                                SELECT o.*, @Now FROM erp_err.ErrorOccurrence o
                                JOIN @moving m ON m.OccurrenceId = o.OccurrenceId;

                                DELETE o FROM erp_err.ErrorOccurrence o
                                JOIN @moving m ON m.OccurrenceId = o.OccurrenceId;
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
                        DELETE TOP (@batch) FROM erp_err.ErrorOccurrence_Archive WHERE OccurredUtc < @purgeCutoff;
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

                        INSERT @movingT (TicketId)
                        SELECT TOP (@batch) t.TicketId
                        FROM erp_err.Ticket t
                        JOIN erp_err.TicketStatus s ON s.StatusId = t.StatusId
                        WHERE s.IsTerminal = 1 AND t.ClosedUtc IS NOT NULL AND t.ClosedUtc < @cutoff
                        ORDER BY t.ClosedUtc;

                        SET @rows = @@ROWCOUNT;

                        IF @rows > 0
                        BEGIN
                            INSERT erp_err.TicketStatusHistory_Archive
                            SELECT h.*, @Now FROM erp_err.TicketStatusHistory h
                            JOIN @movingT m ON m.TicketId = h.TicketId;

                            INSERT erp_err.TicketComment_Archive
                            SELECT c.*, @Now FROM erp_err.TicketComment c
                            JOIN @movingT m ON m.TicketId = c.TicketId;

                            INSERT erp_err.Ticket_Archive
                            SELECT t.*, @Now FROM erp_err.Ticket t
                            JOIN @movingT m ON m.TicketId = t.TicketId;

                            /* Release every reference before deleting the ticket. */
                            UPDATE o SET TicketId = NULL
                            FROM erp_err.ErrorOccurrence o
                            JOIN @movingT m ON m.TicketId = o.TicketId;

                            UPDATE f SET OpenTicketId = NULL
                            FROM erp_err.ErrorFingerprint f
                            JOIN @movingT m ON m.TicketId = f.OpenTicketId;

                            DELETE li FROM erp_err.TicketOccurrenceLink li
                            JOIN @movingT m ON m.TicketId = li.TicketId;

                            /* TicketStatusHistory and TicketComment cascade. */
                            DELETE t FROM erp_err.Ticket t JOIN @movingT m ON m.TicketId = t.TicketId;
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
                    DELETE TOP (@batch) FROM erp_err.ConfigAudit WHERE ChangedUtc < @cutoff;
                    SET @rows = @@ROWCOUNT; SET @totalPurged += @rows; SET @batches += 1;
                END
                SET @rows = 1; SET @batches = 0;
                WHILE @rows > 0 AND @batches < @MaxBatches
                BEGIN
                    DELETE TOP (@batch) FROM erp_err.DeadLetter WHERE ReceivedUtc < @cutoff;
                    SET @rows = @@ROWCOUNT; SET @totalPurged += @rows; SET @batches += 1;
                END
            END

            UPDATE erp_err.RetentionRunLog
               SET FinishedUtc = SYSUTCDATETIME(), RowsArchived = @totalArchived,
                   RowsPurged = @totalPurged, Succeeded = 1
             WHERE RunId = @RunId;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            UPDATE erp_err.RetentionRunLog
               SET FinishedUtc = SYSUTCDATETIME(), RowsArchived = @totalArchived,
                   RowsPurged = @totalPurged, Succeeded = 0, ErrorMessage = ERROR_MESSAGE()
             WHERE RunId = @RunId;
        END CATCH

        FETCH NEXT FROM cur INTO @ds, @archDays, @purgeDays, @batch;
    END
    CLOSE cur; DEALLOCATE cur;

    SELECT DataSet, StartedUtc, FinishedUtc, RowsArchived, RowsPurged, Succeeded, ErrorMessage
    FROM erp_err.RetentionRunLog
    WHERE StartedUtc >= @Now
    ORDER BY RunId;
END
GO

/* Unified read across hot + archive, for the rare "find that error from last
   year" case.  Deliberately a view and not the default search path.          */
CREATE OR ALTER VIEW erp_err.vw_ErrorOccurrence_All
AS
    SELECT CONVERT(BIT,0) AS IsArchived, o.OccurrenceId, o.ErrorReference, o.FingerprintId,
           o.OccurredUtc, o.LayerId, o.CategoryId, o.SeverityId, o.ExceptionType, o.Message,
           o.ErpModule, o.Screen, o.Component, o.ApiEndpoint, o.SqlErrorNumber, o.SqlObjectName,
           o.UserName, o.CorrelationId, o.Environment, o.TicketId
    FROM erp_err.ErrorOccurrence o
    UNION ALL
    SELECT CONVERT(BIT,1) AS IsArchived, a.OccurrenceId, a.ErrorReference, a.FingerprintId,
           a.OccurredUtc, a.LayerId, a.CategoryId, a.SeverityId, a.ExceptionType, a.Message,
           a.ErpModule, a.Screen, a.Component, a.ApiEndpoint, a.SqlErrorNumber, a.SqlObjectName,
           a.UserName, a.CorrelationId, a.Environment, a.TicketId
    FROM erp_err.ErrorOccurrence_Archive a;
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
           ON erp_err.ErrorOccurrence_Archive (OccurredUtc)
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
            @command = N'EXEC erp_err.usp_Retention_Apply;';
       EXEC msdb.dbo.sp_add_jobschedule
            @job_name = N'ERP Error Mgmt - Retention',
            @name = N'Nightly 02:15',
            @freq_type = 4, @freq_interval = 1, @active_start_time = 021500;
       EXEC msdb.dbo.sp_add_jobserver @job_name = N'ERP Error Mgmt - Retention';
   ----------------------------------------------------------------------------- */

MERGE erp_err.SchemaVersion AS t
USING (SELECT N'005_retention_and_archive.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion) VALUES (s.ScriptName, N'1.0.0');
GO
