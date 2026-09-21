/* =============================================================================
   ERP Error Management Framework - VERIFY
   -----------------------------------------------------------------------------
   Run this AFTER RUN_ALL.sql, on the same database, and send me the output.

   Everything here is READ-ONLY except section 8, which inserts one error and
   one ticket and then DELETES BOTH. Nothing else is written. It touches no
   object outside [ERM].

   This is the check I cannot do myself: I have no SQL Server instance, so the
   T-SQL has been parsed against the real SQL Server 2016 grammar but never
   EXECUTED. Parsing catches syntax. It does not catch a wrong column name in a
   valid statement, a type mismatch, or a constraint that fires when it should
   not. That is what this finds.

   In SSMS, switch results to text (Ctrl+T) before running - it makes the output
   far easier to paste back.
   ============================================================================= */

SET NOCOUNT ON;
GO

PRINT '';
PRINT '========================================================';
PRINT ' 1. Which scripts applied?  (expect 10 rows)';
PRINT '========================================================';
SELECT ScriptName, FrameworkVersion, AppliedUtc, AppliedBy
FROM   ERM.ERM_SchemaVersion
ORDER  BY ScriptName;
GO

PRINT '';
PRINT '========================================================';
PRINT ' 2. Object inventory  (tables / procs / functions / views)';
PRINT '========================================================';
SELECT o.type_desc, COUNT(*) AS ObjectCount
FROM   sys.objects o
JOIN   sys.schemas s ON s.schema_id = o.schema_id
WHERE  s.name = N'ERM' AND o.is_ms_shipped = 0
GROUP  BY o.type_desc
ORDER  BY o.type_desc;
GO

PRINT '';
PRINT '========================================================';
PRINT ' 3. STANDARDS: every table has the nine standard columns';
PRINT '    Any row returned here is a table that BREAKS the standard.';
PRINT '========================================================';
SELECT t.name AS TableName,
       SUM(CASE WHEN c.name = 'ROWID'       THEN 1 ELSE 0 END) AS HasROWID,
       SUM(CASE WHEN c.name = 'DBNo'        THEN 1 ELSE 0 END) AS HasDBNo,
       SUM(CASE WHEN c.name = 'AppNo'       THEN 1 ELSE 0 END) AS HasAppNo,
       SUM(CASE WHEN c.name = 'IsActive'    THEN 1 ELSE 0 END) AS HasIsActive,
       SUM(CASE WHEN c.name = 'IsDeleted'   THEN 1 ELSE 0 END) AS HasIsDeleted,
       SUM(CASE WHEN c.name = 'CreatedBy'   THEN 1 ELSE 0 END) AS HasCreatedBy,
       SUM(CASE WHEN c.name = 'CreatedDate' THEN 1 ELSE 0 END) AS HasCreatedDate,
       SUM(CASE WHEN c.name = 'UpdatedBy'   THEN 1 ELSE 0 END) AS HasUpdatedBy,
       SUM(CASE WHEN c.name = 'UpdatedDate' THEN 1 ELSE 0 END) AS HasUpdatedDate
FROM   sys.tables t
JOIN   sys.schemas s ON s.schema_id = t.schema_id
JOIN   sys.columns c ON c.object_id = t.object_id
WHERE  s.name = N'ERM'
  AND  t.name NOT LIKE '%_Archive'      -- copies of the tables above
GROUP  BY t.name
HAVING SUM(CASE WHEN c.name IN ('ROWID','DBNo','AppNo','IsActive','IsDeleted',
                                'CreatedBy','CreatedDate','UpdatedBy','UpdatedDate')
                THEN 1 ELSE 0 END) < 9
ORDER  BY t.name;
PRINT '  (no rows above = every table carries all nine)';
GO

PRINT '';
PRINT '========================================================';
PRINT ' 4. ATC RULE: no default on CreatedBy / UpdatedBy';
PRINT '    Any row returned here is a violation.';
PRINT '========================================================';
SELECT t.name AS TableName, c.name AS ColumnName, d.definition
FROM   sys.default_constraints d
JOIN   sys.columns c ON c.object_id = d.parent_object_id AND c.column_id = d.parent_column_id
JOIN   sys.tables  t ON t.object_id = d.parent_object_id
JOIN   sys.schemas s ON s.schema_id = t.schema_id
WHERE  s.name = N'ERM' AND c.name IN ('CreatedBy','UpdatedBy');
PRINT '  (no rows above = correct)';
GO

PRINT '';
PRINT '========================================================';
PRINT ' 5. The non-user value is ATC''s -1';
PRINT '========================================================';
SELECT ERM.fn_SystemUserID() AS SystemUserID_ShouldBe_Minus1;
GO

PRINT '';
PRINT '========================================================';
PRINT ' 6. Reference codes: format and per-day counters';
PRINT '========================================================';
DECLARE @r1 VARCHAR(30), @r2 VARCHAR(30), @t1 VARCHAR(30);
EXEC ERM.usp_NextReference @RefType = 'ERR', @Reference = @r1 OUTPUT;
EXEC ERM.usp_NextReference @RefType = 'ERR', @Reference = @r2 OUTPUT;
EXEC ERM.usp_NextReference @RefType = 'TKT', @Reference = @t1 OUTPUT;
SELECT @r1 AS FirstError, @r2 AS SecondError, @t1 AS FirstTicket;
PRINT '  expect LS-ERM-ERR-YYMMDD-n, the second one higher, and the';
PRINT '  ticket counter numbering INDEPENDENTLY of the error counter.';
GO

PRINT '';
PRINT '========================================================';
PRINT ' 7. Configuration loaded  (severities / categories / statuses / etc.)';
PRINT '========================================================';
SELECT 'Severity' AS TableName, COUNT(*) AS Rows FROM ERM.ERM_Severity
UNION ALL SELECT 'ErrorCategory',   COUNT(*) FROM ERM.ERM_ErrorCategory
UNION ALL SELECT 'AppLayer',        COUNT(*) FROM ERM.ERM_AppLayer
UNION ALL SELECT 'TicketStatus',    COUNT(*) FROM ERM.ERM_TicketStatus
UNION ALL SELECT 'StatusTransition',COUNT(*) FROM ERM.ERM_TicketStatusTransition
UNION ALL SELECT 'TicketQueue',     COUNT(*) FROM ERM.ERM_TicketQueue
UNION ALL SELECT 'SlaPolicy',       COUNT(*) FROM ERM.ERM_SlaPolicy
UNION ALL SELECT 'Setting',         COUNT(*) FROM ERM.ERM_Setting
UNION ALL SELECT 'RedactionAllow',  COUNT(*) FROM ERM.ERM_RedactionAllowList
UNION ALL SELECT 'RetentionPolicy', COUNT(*) FROM ERM.ERM_RetentionPolicy
UNION ALL SELECT 'SortWhitelist',   COUNT(*) FROM ERM.ERM_SortWhitelist
UNION ALL SELECT 'SupportRole',     COUNT(*) FROM ERM.ERM_SupportRole
UNION ALL SELECT 'RequestCategory', COUNT(*) FROM ERM.ERM_RequestCategory;
PRINT '  every count should be > 0.';
GO

PRINT '';
PRINT '========================================================';
PRINT ' 8. THE REAL TEST: capture an error, raise a ticket, move it,';
PRINT '    then clean up. This is the only part that writes.';
PRINT '========================================================';

DECLARE @Envelope NVARCHAR(MAX) = N'{
  "fingerprintHash": "0000000000000000000000000000000000000000000000000000000000000001",
  "signatureText": "VERIFY.sql smoke test",
  "layer": "database",
  "category": "sql_procedure",
  "severity": "high",
  "exceptionType": "System.Data.SqlClient.SqlException",
  "message": "VERIFY.sql smoke test - safe to delete",
  "normalizedMessage": "VERIFY.sql smoke test - safe to delete",
  "occurredUtc": "2026-09-19T12:00:00.000Z",
  "erpModule": "VERIFY",
  "screen": "VERIFY",
  "environment": "Test",
  "user": { "profileId": -1, "name": "verify.sql" },
  "sql": { "number": 1205, "objectName": "usp_Verify" }
}';

DECLARE @ErrRef VARCHAR(30), @OccId BIGINT, @FpId BIGINT;

BEGIN TRY
    DECLARE @CaptureResult TABLE
    (
        ErrorReference VARCHAR(30), OccurrenceId BIGINT, FingerprintId BIGINT,
        ShouldNotifyUser BIT, AutoTicketNumber VARCHAR(30), IsKnownIssue BIT
    );

    INSERT @CaptureResult
    EXEC ERM.usp_Error_Capture @EnvelopeJson = @Envelope, @Source = N'verify';

    SELECT @ErrRef = ErrorReference, @OccId = OccurrenceId, @FpId = FingerprintId
    FROM @CaptureResult;

    SELECT 'CAPTURE' AS Step, @ErrRef AS ErrorReference, @OccId AS OccurrenceId,
           @FpId AS FingerprintId;

    IF @OccId IS NULL
    BEGIN
        PRINT '  *** CAPTURE RETURNED NO OCCURRENCE - check ERM.ERM_DeadLetter ***';
        SELECT TOP 5 * FROM ERM.ERM_DeadLetter ORDER BY ERM_DeadLetterID DESC;
    END
    ELSE
    BEGIN
        /* The nine standard columns, populated, on a real captured row. */
        SELECT 'STANDARD COLUMNS' AS Step, ROWID, DBNo, AppNo, IsActive, IsDeleted,
               CreatedBy, CreatedDate, UpdatedBy, UpdatedDate, UserProfileID
        FROM   ERM.ERM_ErrorOccurrence WHERE ERM_ErrorOccurrenceID = @OccId;

        DECLARE @TicketNo VARCHAR(30);
        EXEC ERM.usp_Ticket_Create
             @ERM_ErrorOccurrenceID   = @OccId,
             @CreatedVia              = N'user',
             @UserDescription         = N'VERIFY.sql smoke test',
             @ReportedByUserProfileID = 1,
             @ReportedByUserName      = N'verify.sql',
             @TicketNumber            = @TicketNo OUTPUT;

        SELECT 'TICKET' AS Step, @TicketNo AS TicketNumber;

        DECLARE @TicketId BIGINT =
            (SELECT ERM_TicketID FROM ERM.ERM_Ticket WHERE TicketNumber = @TicketNo);

        /* New -> In Progress. Exercises the workflow table, the audit row and
           the minutes-in-status accounting. */
        EXEC ERM.usp_Ticket_ChangeStatus
             @ERM_TicketID           = @TicketId,
             @ToStatusID             = 3,
             @ChangedByUserProfileID = 1,
             @ChangedByUserName      = N'verify.sql',
             @Comments               = N'VERIFY.sql smoke test';

        SELECT 'AUDIT TRAIL' AS Step, SequenceNo, FromStatusID, ToStatusID,
               ChangedByUserProfileID, ChangeKind, MinutesInFromStatus, CreatedBy
        FROM   ERM.ERM_TicketStatusHistory
        WHERE  ERM_TicketID = @TicketId ORDER BY SequenceNo;

        /* Ownership: user 1 owns it, user 2 must not. */
        SELECT 'OWNERSHIP' AS Step,
               ERM.fn_UserOwnsTicket(@TicketId, 1)  AS Owner_ShouldBe_1,
               ERM.fn_UserOwnsTicket(@TicketId, 2)  AS OtherUser_ShouldBe_0,
               ERM.fn_UserOwnsTicket(@TicketId, -1) AS NonUser_ShouldBe_0;

        /* Authorisation must fail closed for somebody not on the roster. */
        SELECT 'AUTHORISATION' AS Step,
               ERM.fn_SupportCapability(999999, N'manage') AS Stranger_ShouldBe_0,
               ERM.fn_SupportCapability(-1,     N'manage') AS NonUser_ShouldBe_0,
               ERM.fn_SupportCapability(NULL,   N'manage') AS Null_ShouldBe_0;

        /* Notification outbox: the ticket events above should have queued rows,
           all still 'pending' because the adapter is not wired up yet. */
        SELECT 'NOTIFICATIONS' AS Step, EventKind, RecipientUserProfileID,
               DeliveryState, AttemptCount
        FROM   ERM.ERM_NotificationOutbox
        WHERE  ERM_TicketID = @TicketId ORDER BY ERM_NotificationOutboxID;

        /* The search procedures - these are the dynamic ones, so this is the
           first time the SQL they BUILD runs on a real server. */
        PRINT '  -- usp_Error_Search --';
        EXEC ERM.usp_Error_Search  @ErpModule = N'VERIFY', @PageNumber = 1, @PageSize = 5;
        PRINT '  -- usp_Ticket_Search --';
        EXEC ERM.usp_Ticket_Search @PageNumber = 1, @PageSize = 5;
        PRINT '  -- usp_Error_RecurringProblems --';
        EXEC ERM.usp_Error_RecurringProblems @MinOccurrences = 1;
        PRINT '  -- usp_Dashboard_Summary --';
        EXEC ERM.usp_Dashboard_Summary;
        PRINT '  -- usp_Ticket_GetDetail --';
        EXEC ERM.usp_Ticket_GetDetail @TicketNumber = @TicketNo;
        PRINT '  -- usp_Ticket_ListForUser (end user) --';
        EXEC ERM.usp_Ticket_ListForUser @UserProfileID = 1;

        /* Retention, reporting only - changes nothing. */
        PRINT '  -- usp_Retention_Apply @WhatIf = 1 --';
        EXEC ERM.usp_Retention_Apply @WhatIf = 1;

        /* ---- clean up everything this section created ---------------- */
        DELETE FROM ERM.ERM_NotificationOutbox WHERE ERM_TicketID = @TicketId;
        DELETE FROM ERM.ERM_TicketStatusHistory WHERE ERM_TicketID = @TicketId;
        DELETE FROM ERM.ERM_TicketComment       WHERE ERM_TicketID = @TicketId;
        DELETE FROM ERM.ERM_TicketOccurrenceLink WHERE ERM_TicketID = @TicketId;
        UPDATE ERM.ERM_ErrorFingerprint SET OpenTicketID = NULL WHERE OpenTicketID = @TicketId;
        UPDATE ERM.ERM_ErrorOccurrence  SET ERM_TicketID = NULL WHERE ERM_TicketID = @TicketId;
        DELETE FROM ERM.ERM_Ticket               WHERE ERM_TicketID = @TicketId;
        DELETE FROM ERM.ERM_ErrorOccurrenceDetail WHERE ERM_ErrorOccurrenceID = @OccId;
        DELETE FROM ERM.ERM_ErrorOccurrence      WHERE ERM_ErrorOccurrenceID = @OccId;
        DELETE FROM ERM.ERM_ErrorFingerprint     WHERE ERM_ErrorFingerprintID = @FpId;

        PRINT '  smoke-test rows removed.';
    END
END TRY
BEGIN CATCH
    /* The whole point: if anything above fails, I need the real error, not a
       swallowed one. */
    SELECT 'FAILED' AS Step, ERROR_NUMBER() AS ErrNumber, ERROR_SEVERITY() AS Severity,
           ERROR_STATE() AS ErrState, ERROR_PROCEDURE() AS ErrProcedure,
           ERROR_LINE() AS ErrLine, ERROR_MESSAGE() AS ErrMessage;
END CATCH
GO

PRINT '';
PRINT '========================================================';
PRINT ' 9. Dead letters  (capture failures - should be empty)';
PRINT '========================================================';
SELECT TOP 20 ERM_DeadLetterID, Source, FailureReason, ReceivedUtc
FROM   ERM.ERM_DeadLetter ORDER BY ERM_DeadLetterID DESC;
PRINT '  (no rows above = nothing failed quietly)';
GO

PRINT '';
PRINT '========================================================';
PRINT ' 10. Left-over rows from this run  (all should be 0)';
PRINT '========================================================';
SELECT 'Occurrence'   AS TableName, COUNT(*) AS LeftOver FROM ERM.ERM_ErrorOccurrence  WHERE ErpModule = N'VERIFY'
UNION ALL SELECT 'Fingerprint', COUNT(*) FROM ERM.ERM_ErrorFingerprint WHERE ErpModule = N'VERIFY'
UNION ALL SELECT 'Ticket',      COUNT(*) FROM ERM.ERM_Ticket WHERE UserDescription = N'VERIFY.sql smoke test';
GO

PRINT '';
PRINT '=== VERIFY complete. Please send me everything above. ===';
GO
