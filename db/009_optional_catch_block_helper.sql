/* =============================================================================
   ERP Error Management Framework
   Script 009 - OPTIONAL: one-line capture from inside an existing CATCH block

   ┌───────────────────────────────────────────────────────────────────────────┐
   │ OPTIONAL, like 008 - but this is the one I would actually recommend      │
   │ first.  It solves the same problem (errors a procedure swallows) with no  │
   │ server-level permissions, no Extended Events session, no scheduled        │
   │ collector, and no noise.                                                 │
   └───────────────────────────────────────────────────────────────────────────┘

   THE TRADE, STATED PLAINLY
   -------------------------
   008 is automatic but instance-wide, noisy, and needs ALTER ANY EVENT SESSION.
   009 is precise, silent and database-scoped - but it is NOT automatic: each
   CATCH block you care about gains one line.

   For most ERPs 009 wins, because the swallowed errors that matter are not
   spread across every procedure.  They are concentrated in a handful of known
   TRY/CATCH blocks - the posting routines, the batch jobs, the integration
   procedures - and instrumenting those by hand is a morning's work that
   produces clean data, rather than a permanent XE session producing data
   somebody has to keep filtering.

   Adding the line does NOT change the procedure's behaviour: it does not
   re-raise, it does not roll back, it does not alter the return value, and it
   cannot fail in a way the caller can see.  It is one EXEC inside a block that
   was already there.

   USAGE - the whole integration for a procedure
   ---------------------------------------------
       BEGIN CATCH
           EXEC ERM.usp_Error_CaptureFromCatch @ProcedureName = N'usp_PostJournal';

           SET @Result = -1;          -- unchanged
           -- no THROW, as before    -- unchanged
       END CATCH

   With no arguments at all it still works - it reads ERROR_PROCEDURE() -
   but passing @ProcedureName explicitly is better: ERROR_PROCEDURE() returns
   the procedure where the error was RAISED, which for nested calls is the inner
   one, and grouping by the outer one is usually what you want.

   Idempotent: yes.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =============================================================================
   usp_Error_CaptureFromCatch
   -----------------------------------------------------------------------------
   MUST be called from inside a CATCH block - it reads the ERROR_* functions,
   which return NULL anywhere else.  Called outside one, it does nothing rather
   than writing a row full of NULLs.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Error_CaptureFromCatch
(
    /* Name to group by.  Defaults to ERROR_PROCEDURE(), which is the procedure
       that RAISED the error - for a nested call that is the inner one, so pass
       the outer name explicitly if you want the grouping at that level. */
    @ProcedureName  NVARCHAR(256) = NULL,

    /* Optional business context.  A document number or batch id makes a
       swallowed posting error diagnosable instead of merely countable.
       Business keys only - this goes into the error store. */
    @ContextKey     NVARCHAR(200) = NULL,

    /* Correlation id, if the calling procedure has it.  Passing it joins this
       row to the Angular and API rows for the same user action, which is the
       difference between "an error happened in the database at 14:02" and
       "THIS user's save at 14:02 failed for THIS reason".

       See the note at the bottom on how to make this automatic with
       sp_set_session_context, which needs no procedure signature changes. */
    @CorrelationID  UNIQUEIDENTIFIER = NULL,

    @ErpModule      NVARCHAR(100) = NULL,
    @Severity       NVARCHAR(20)  = NULL   -- override; default derives from ERROR_SEVERITY()
)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        /* Not in a CATCH block: nothing to capture.  Silent, because this
           procedure is called from error paths and must never add an error. */
        IF ERROR_NUMBER() IS NULL RETURN;

        DECLARE @Number   INT           = ERROR_NUMBER();
        DECLARE @Sev      INT           = ERROR_SEVERITY();
        DECLARE @State    INT           = ERROR_STATE();
        DECLARE @Line     INT           = ERROR_LINE();
        DECLARE @Message  NVARCHAR(2000) = LEFT(ERROR_MESSAGE(), 2000);
        DECLARE @Proc     NVARCHAR(256) = COALESCE(@ProcedureName, ERROR_PROCEDURE());

        /* ---- correlation: explicit argument, else session context -------- */
        IF @CorrelationID IS NULL
        BEGIN
            /* Set once per connection by the data-access layer; see the note at
               the bottom.  TRY_CONVERT so a malformed value is ignored rather
               than throwing inside an error handler. */
            SET @CorrelationID = TRY_CONVERT(UNIQUEIDENTIFIER,
                                             SESSION_CONTEXT(N'ERM_correlation_id'));
        END

        IF @ErpModule IS NULL
            SET @ErpModule = CONVERT(NVARCHAR(100), SESSION_CONTEXT(N'ERM_module'));

        /* ---- severity ---------------------------------------------------- */
        /* Same reasoning as the .NET classifier: a RAISERROR at severity 11-16
           inside a procedure is usually a business rule being enforced on
           purpose, not a system failure.  17+ is a genuine server-side fault. */
        IF @Severity IS NULL
            SET @Severity = CASE WHEN @Sev >= 17 THEN N'critical'
                                 WHEN @Sev >= 16 THEN N'high'
                                 ELSE N'medium' END;

        /* ---- normalise the message -------------------------------------- */
        /* Must follow the same rules as fingerprint.ts / Fingerprint.cs, or the
           same fault reported from here and from .NET would land on two
           different fingerprints - two problems, two tickets, halved counts.

           T-SQL has no regex, so this is a deliberately simple digit-collapse.
           It is strictly less aggressive than the application-side
           normalisation, which is the safe direction: it can split one problem
           into two, but it cannot merge two unrelated ones. */
        DECLARE @Normalised NVARCHAR(2000) = @Message;
        DECLARE @d INT = 0;
        WHILE @d <= 9
        BEGIN
            SET @Normalised = REPLACE(@Normalised, CONVERT(NVARCHAR(1), @d), N'#');
            SET @d += 1;
        END
        WHILE CHARINDEX(N'##', @Normalised) > 0
            SET @Normalised = REPLACE(@Normalised, N'##', N'#');

        /* ---- fingerprint ------------------------------------------------- */
        DECLARE @Signature NVARCHAR(1000) =
              N'database|sql_procedure|SqlCatchBlock|'
            + ISNULL(@Normalised, N'') + N'|'
            + CONVERT(NVARCHAR(20), ISNULL(@Number, 0)) + N'|'
            + ISNULL(@Proc, N'');

        /* HASHBYTES('SHA2_256', NVARCHAR) hashes UTF-16LE bytes, whereas the
           C#/TypeScript sides hash UTF-8.  The two therefore produce DIFFERENT
           digests for the same string - which is correct and intended here,
           because this signature is only ever produced on this side.  What
           matters is that it is STABLE and UNIQUE per problem, and it is.
           Cross-language parity is only required for the envelope path, where
           the hash is computed by the application. */
        DECLARE @Hash CHAR(64) =
            LOWER(CONVERT(CHAR(64), HASHBYTES('SHA2_256', @Signature), 2));

        /* ---- build the envelope ------------------------------------------ */
        DECLARE @Envelope NVARCHAR(MAX) =
        (
            SELECT
                @Hash                    AS fingerprintHash,
                @Signature               AS signatureText,
                N'database'              AS layer,
                N'sql_procedure'         AS category,
                @Severity                AS severity,
                N'SqlCatchBlock'         AS exceptionType,
                @Message                 AS message,
                @Normalised              AS normalizedMessage,
                CONVERT(NVARCHAR(40), SYSUTCDATETIME(), 127) AS occurredUtc,
                @ErpModule               AS erpModule,
                CONVERT(NVARCHAR(36), @CorrelationID) AS correlationId,
                ISNULL(CONVERT(NVARCHAR(40), SESSION_CONTEXT(N'ERM_environment')),
                       N'SQL Server')    AS environment,
                @@SERVERNAME             AS machineName,
                @Number                  AS [sql.number],
                @Sev                     AS [sql.severity],
                @State                   AS [sql.state],
                @Proc                    AS [sql.objectName],
                @Line                    AS [sql.lineNumber],
                @@SERVERNAME             AS [sql.serverName],
                DB_NAME()                AS [sql.databaseName],
                OBJECT_SCHEMA_NAME(@@PROCID) AS [sql.schemaName],
                /* The business key, under customData rather than as a column:
                   it is caller-supplied and its meaning varies by procedure. */
                @ContextKey              AS [customData.contextKey],
                SUSER_SNAME()            AS [user.name]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
        );

        /* usp_Error_Capture never raises for a data problem - it dead-letters
           and returns - so this call is safe from inside an error handler. */
        DECLARE @sink TABLE
        (
            ErrorReference VARCHAR(30), ERM_ErrorOccurrenceID BIGINT, ERM_ErrorFingerprintID BIGINT,
            ShouldNotifyUser BIT, AutoTicketNumber VARCHAR(30), IsKnownIssue BIT
        );

        INSERT @sink
        EXEC ERM.usp_Error_Capture @EnvelopeJson = @Envelope, @Source = N'sql-catch';
    END TRY
    BEGIN CATCH
        /* An error inside the error capture, inside the caller's CATCH block.
           There is exactly one correct behaviour: absorb it.  Re-raising here
           would replace the caller's original error with ours, which is the
           single most destructive thing an error framework can do.

           Not even a dead-letter INSERT is attempted - that is what failed. */
        RETURN;
    END CATCH
END
GO

/* =============================================================================
   Optional: make correlation automatic
   -----------------------------------------------------------------------------
   The capture above works with no correlation id, but the row is then only
   joinable by time.  To get the full cross-layer trail without changing a
   single procedure signature, have the data-access layer stamp the connection
   once per request:

       -- called by the SP executor immediately after opening the connection
       EXEC ERM.usp_Session_SetContext
            @CorrelationID = @correlationFromHttpHeader,
            @ErpModule     = @moduleFromHttpHeader,
            @Environment   = N'Production';

   Every subsequent CATCH on that connection then picks the values up from
   SESSION_CONTEXT automatically.  One call in one place in the ADO.NET SP
   executor, and every instrumented CATCH block in the database inherits it.

   SESSION_CONTEXT is connection-scoped, so pooling is safe as long as it is set
   per request rather than per pooled connection - which the call above does.
   @read_only is deliberately NOT used: a pooled connection is reused for the
   next request, which must be able to overwrite the previous value.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Session_SetContext
(
    @CorrelationID UNIQUEIDENTIFIER = NULL,
    @ErpModule     NVARCHAR(100) = NULL,
    @Environment   NVARCHAR(40)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        EXEC sp_set_session_context @key = N'ERM_correlation_id',
                                    @value = @CorrelationID;
        EXEC sp_set_session_context @key = N'ERM_module',
                                    @value = @ErpModule;
        EXEC sp_set_session_context @key = N'ERM_environment',
                                    @value = @Environment;
    END TRY
    BEGIN CATCH
        /* Setting diagnostic context must never fail a request.  Without it the
           capture still works, just without correlation. */
        RETURN;
    END CATCH
END
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'009_optional_catch_block_helper.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.1.0-optional', ERM.fn_SystemUserID());
GO
