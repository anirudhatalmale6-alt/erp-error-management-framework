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
   Helper: reference-number formatting
   ============================================================================= */
CREATE OR ALTER FUNCTION erp_err.fn_FormatReference
(
    @Prefix     VARCHAR(8),
    @Seq        BIGINT,
    @WhenUtc    DATETIME2(3)
)
RETURNS VARCHAR(24)
AS
BEGIN
    RETURN @Prefix + '-' + CONVERT(VARCHAR(4), DATEPART(YEAR, @WhenUtc)) + '-'
         + RIGHT('00000000' + CONVERT(VARCHAR(20), @Seq), 8);
END
GO

/* =============================================================================
   Helper: read a typed setting
   ============================================================================= */
CREATE OR ALTER FUNCTION erp_err.fn_SettingInt (@Key NVARCHAR(100), @Default INT)
RETURNS INT
AS
BEGIN
    DECLARE @v NVARCHAR(400) = (SELECT SettingValue FROM erp_err.Setting WHERE SettingKey = @Key);
    RETURN CASE WHEN @v IS NULL OR TRY_CONVERT(INT, @v) IS NULL THEN @Default ELSE CONVERT(INT, @v) END;
END
GO

CREATE OR ALTER FUNCTION erp_err.fn_SettingBit (@Key NVARCHAR(100), @Default BIT)
RETURNS BIT
AS
BEGIN
    DECLARE @v NVARCHAR(400) = (SELECT LOWER(SettingValue) FROM erp_err.Setting WHERE SettingKey = @Key);
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
   malformed or unexpected envelope goes to erp_err.DeadLetter and the procedure
   returns a NULL reference.  Capture must not be able to take down the ERP.
   ============================================================================= */
CREATE OR ALTER PROCEDURE erp_err.usp_Error_Capture
(
    @EnvelopeJson   NVARCHAR(MAX),
    @Source         NVARCHAR(60) = NULL     -- 'angular' | 'webapi2' | 'aspnetcore'
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF erp_err.fn_SettingBit(N'capture.enabled', 1) = 0
        BEGIN
            SELECT CONVERT(VARCHAR(24), NULL) AS ErrorReference,
                   CONVERT(BIGINT, NULL)      AS OccurrenceId,
                   CONVERT(BIGINT, NULL)      AS FingerprintId,
                   CONVERT(BIT, 0)            AS ShouldNotifyUser,
                   CONVERT(VARCHAR(24), NULL) AS AutoTicketNumber,
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
            UserId            NVARCHAR(128),
            UserName          NVARCHAR(200),
            UserDisplayName   NVARCHAR(200),
            TenantId          NVARCHAR(64),
            SessionId         NVARCHAR(100),
            ClientIp          NVARCHAR(64),
            CorrelationId     UNIQUEIDENTIFIER,
            RequestId         UNIQUEIDENTIFIER,
            ParentErrorReference VARCHAR(24),
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
            UserId            NVARCHAR(128)   '$.user.id',
            UserName          NVARCHAR(200)   '$.user.name',
            UserDisplayName   NVARCHAR(200)   '$.user.displayName',
            TenantId          NVARCHAR(64)    '$.user.tenantId',
            SessionId         NVARCHAR(100)   '$.user.sessionId',
            ClientIp          NVARCHAR(64)    '$.user.clientIp',
            CorrelationId     UNIQUEIDENTIFIER '$.correlationId',
            RequestId         UNIQUEIDENTIFIER '$.requestId',
            ParentErrorReference VARCHAR(24)  '$.parentErrorReference',
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
        DECLARE @LayerId TINYINT, @CategoryId SMALLINT, @SeverityId TINYINT;

        SELECT @LayerId = ISNULL((SELECT LayerId FROM erp_err.AppLayer l
                                  WHERE l.Code = (SELECT LayerCode FROM @e)), 8);

        SELECT @CategoryId = ISNULL((SELECT CategoryId FROM erp_err.ErrorCategory c
                                     WHERE c.Code = (SELECT CategoryCode FROM @e) AND c.IsActive = 1), 99);

        SELECT @SeverityId = COALESCE(
                    (SELECT SeverityId FROM erp_err.Severity s
                     WHERE s.Code = (SELECT SeverityCode FROM @e) AND s.IsActive = 1),
                    (SELECT DefaultSeverityId FROM erp_err.ErrorCategory WHERE CategoryId = @CategoryId),
                    3);

        DECLARE @Hash CHAR(64) = (SELECT FingerprintHash FROM @e);
        IF @Hash IS NULL OR LEN(@Hash) <> 64
        BEGIN
            /* No usable fingerprint: refuse to guess, dead-letter and get out.
               A wrong fingerprint is worse than none - it silently merges two
               unrelated problems into one ticket. */
            INSERT erp_err.DeadLetter (Source, RawEnvelopeJson, FailureReason)
            VALUES (@Source, @EnvelopeJson, N'Missing or malformed fingerprintHash');

            SELECT CONVERT(VARCHAR(24), NULL) AS ErrorReference, CONVERT(BIGINT, NULL) AS OccurrenceId,
                   CONVERT(BIGINT, NULL) AS FingerprintId, CONVERT(BIT, 1) AS ShouldNotifyUser,
                   CONVERT(VARCHAR(24), NULL) AS AutoTicketNumber, CONVERT(BIT, 0) AS IsKnownIssue;
            RETURN;
        END

        DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
        DECLARE @OccurredUtc DATETIME2(3) = ISNULL((SELECT OccurredUtc FROM @e), @Now);

        /* A client clock can be wildly wrong.  Clamp rather than trust: a 2031
           timestamp would sit at the top of every "recent errors" list forever. */
        IF @OccurredUtc > DATEADD(MINUTE, 5, @Now) OR @OccurredUtc < DATEADD(YEAR, -1, @Now)
            SET @OccurredUtc = @Now;

        DECLARE @FingerprintId BIGINT, @OccurrenceId BIGINT, @ErrorReference VARCHAR(24);
        DECLARE @IsKnownIssue BIT = 0, @IsMuted BIT = 0, @OpenTicketId BIGINT = NULL;

        BEGIN TRANSACTION;

            /* ---- upsert the fingerprint -------------------------------- */
            MERGE erp_err.ErrorFingerprint WITH (HOLDLOCK) AS t
            USING (SELECT @Hash AS FingerprintHash) AS s
                ON t.FingerprintHash = s.FingerprintHash
            WHEN MATCHED THEN
                UPDATE SET LastSeenUtc     = CASE WHEN @OccurredUtc > t.LastSeenUtc THEN @OccurredUtc ELSE t.LastSeenUtc END,
                           OccurrenceCount = t.OccurrenceCount + 1,
                           -- Escalate, never de-escalate: if the same problem was
                           -- ever seen as critical, it stays critical.
                           SeverityId      = CASE WHEN @SeverityId < t.SeverityId THEN @SeverityId ELSE t.SeverityId END
            WHEN NOT MATCHED THEN
                INSERT (FingerprintHash, SignatureText, LayerId, CategoryId, SeverityId,
                        ExceptionType, NormalizedMessage, ErpModule, Screen, Component,
                        ApiEndpoint, SqlObjectName, FirstSeenUtc, LastSeenUtc, OccurrenceCount)
                VALUES (@Hash,
                        ISNULL((SELECT SignatureText FROM @e), N'(no signature supplied)'),
                        @LayerId, @CategoryId, @SeverityId,
                        (SELECT ExceptionType FROM @e),
                        (SELECT COALESCE(NormalizedMessage, Message) FROM @e),
                        (SELECT ErpModule FROM @e), (SELECT Screen FROM @e), (SELECT Component FROM @e),
                        (SELECT ApiEndpoint FROM @e), (SELECT SqlObjectName FROM @e),
                        @OccurredUtc, @OccurredUtc, 1);

            SELECT @FingerprintId = FingerprintId,
                   @IsKnownIssue  = CASE WHEN TriageState IN (N'known_issue', N'muted') THEN 1 ELSE 0 END,
                   @IsMuted       = CASE WHEN TriageState = N'muted'
                                           OR (MutedUntilUtc IS NOT NULL AND MutedUntilUtc > @Now)
                                         THEN 1 ELSE 0 END,
                   @OpenTicketId  = OpenTicketId
            FROM erp_err.ErrorFingerprint
            WHERE FingerprintHash = @Hash;

            /* ---- sampling: high-volume info noise does not need every row -- */
            DECLARE @InfoPct INT = erp_err.fn_SettingInt(N'capture.sampling.infoPercent', 10);
            IF @SeverityId = 5 AND @InfoPct < 100
               AND (CONVERT(BIGINT, CONVERT(VARBINARY(4), SUBSTRING(@Hash, 1, 8), 2)) % 100) >= @InfoPct
            BEGIN
                /* Counted on the fingerprint above, body not persisted. */
                COMMIT TRANSACTION;
                SELECT CONVERT(VARCHAR(24), NULL) AS ErrorReference, CONVERT(BIGINT, NULL) AS OccurrenceId,
                       @FingerprintId AS FingerprintId, CONVERT(BIT, 0) AS ShouldNotifyUser,
                       CONVERT(VARCHAR(24), NULL) AS AutoTicketNumber, @IsKnownIssue AS IsKnownIssue;
                RETURN;
            END

            /* ---- reference number and occurrence row -------------------- */
            SET @ErrorReference = erp_err.fn_FormatReference('ERR', NEXT VALUE FOR erp_err.ErrorNumberSeq, @Now);

            DECLARE @ParentOccurrenceId BIGINT =
                (SELECT o.OccurrenceId FROM erp_err.ErrorOccurrence o
                 WHERE o.ErrorReference = (SELECT ParentErrorReference FROM @e));

            INSERT erp_err.ErrorOccurrence
            (
                ErrorReference, FingerprintId, OccurredUtc, OccurredLocal, ClientUtcOffsetMin,
                LayerId, CategoryId, SeverityId, ExceptionType, Message,
                ErpModule, Screen, RouteUrl, Component, ActionName, FormName, LovName,
                ApiApplication, ApiController, ApiAction, ApiEndpoint, HttpMethod, HttpStatusCode, DurationMs,
                SqlErrorNumber, SqlErrorSeverity, SqlErrorState, SqlObjectName, SqlLineNumber,
                SqlServerName, SqlDatabaseName, SqlSchemaName,
                UserId, UserName, UserDisplayName, TenantId, SessionId, ClientIp,
                CorrelationId, RequestId, ParentOccurrenceId,
                Environment, AppVersion, MachineName,
                BrowserName, BrowserVersion, OsName, DeviceType, ScreenResolution, Locale
            )
            SELECT
                @ErrorReference, @FingerprintId, @OccurredUtc, e.OccurredLocal, e.ClientUtcOffsetMin,
                @LayerId, @CategoryId, @SeverityId, e.ExceptionType, e.Message,
                e.ErpModule, e.Screen, e.RouteUrl, e.Component, e.ActionName, e.FormName, e.LovName,
                e.ApiApplication, e.ApiController, e.ApiAction, e.ApiEndpoint, e.HttpMethod, e.HttpStatusCode, e.DurationMs,
                e.SqlErrorNumber, e.SqlErrorSeverity, e.SqlErrorState, e.SqlObjectName, e.SqlLineNumber,
                e.SqlServerName, e.SqlDatabaseName, e.SqlSchemaName,
                e.UserId, e.UserName, e.UserDisplayName, e.TenantId, e.SessionId, e.ClientIp,
                ISNULL(e.CorrelationId, NEWID()), e.RequestId, @ParentOccurrenceId,
                ISNULL(e.Environment, N'unknown'), e.AppVersion, e.MachineName,
                e.BrowserName, e.BrowserVersion, e.OsName, e.DeviceType, e.ScreenResolution, e.Locale
            FROM @e e;

            SET @OccurrenceId = SCOPE_IDENTITY();

            DECLARE @MaxStack INT = erp_err.fn_SettingInt(N'capture.maxStackTraceChars', 20000);
            DECLARE @StoreReq BIT = erp_err.fn_SettingBit(N'capture.storeRequestBody', 1);
            DECLARE @StoreRes BIT = erp_err.fn_SettingBit(N'capture.storeResponseBody', 0);

            INSERT erp_err.ErrorOccurrenceDetail
            (
                OccurrenceId, StackTrace, InnerExceptionChain, RequestPayloadJson,
                ResponsePayloadJson, ValidationErrorsJson, BreadcrumbsJson, CustomDataJson, SqlStatementText
            )
            SELECT
                @OccurrenceId,
                CASE WHEN LEN(e.StackTrace) > @MaxStack
                     THEN LEFT(e.StackTrace, @MaxStack) + NCHAR(10) + N'... [truncated at ' + CONVERT(NVARCHAR(20), @MaxStack) + N' chars]'
                     ELSE e.StackTrace END,
                e.InnerExceptionChain,
                CASE WHEN @StoreReq = 1 THEN e.RequestPayloadJson END,
                CASE WHEN @StoreRes = 1 THEN e.ResponsePayloadJson END,
                e.ValidationErrorsJson, e.BreadcrumbsJson, e.CustomDataJson, e.SqlStatementText
            FROM @e e;

            /* Distinct-user count, maintained incrementally so the admin list
               does not have to COUNT(DISTINCT) over a 50-million-row table. */
            IF EXISTS (SELECT 1 FROM @e WHERE UserName IS NOT NULL)
               AND NOT EXISTS (
                    SELECT 1 FROM erp_err.ErrorOccurrence o
                    WHERE o.FingerprintId = @FingerprintId
                      AND o.UserName = (SELECT UserName FROM @e)
                      AND o.OccurrenceId <> @OccurrenceId)
                UPDATE erp_err.ErrorFingerprint
                   SET DistinctUserCount = DistinctUserCount + 1
                 WHERE FingerprintId = @FingerprintId;

            /* ---- attach to an already-open ticket for the same problem --- */
            DECLARE @AutoTicketNumber VARCHAR(24) = NULL;

            IF @OpenTicketId IS NOT NULL AND erp_err.fn_SettingBit(N'ticket.attachRecurrenceToOpen', 1) = 1
            BEGIN
                INSERT erp_err.TicketOccurrenceLink (TicketId, OccurrenceId, LinkReason)
                VALUES (@OpenTicketId, @OccurrenceId, N'deduplicated');

                UPDATE erp_err.Ticket
                   SET LinkedOccurrenceCount = LinkedOccurrenceCount + 1
                 WHERE TicketId = @OpenTicketId;

                UPDATE erp_err.ErrorOccurrence SET TicketId = @OpenTicketId WHERE OccurrenceId = @OccurrenceId;
                SET @AutoTicketNumber = (SELECT TicketNumber FROM erp_err.Ticket WHERE TicketId = @OpenTicketId);
            END

        COMMIT TRANSACTION;

        /* ---- auto-ticket rules (outside the capture transaction on purpose:
                a rule-evaluation problem must not roll back the captured error) */
        IF @AutoTicketNumber IS NULL AND @IsMuted = 0
        BEGIN
            DECLARE @WindowMin INT, @RuleQueueId SMALLINT, @RuleName NVARCHAR(100);

            SELECT TOP 1 @WindowMin = r.WindowMinutes, @RuleQueueId = r.TargetQueueId, @RuleName = r.RuleName
            FROM erp_err.AutoTicketRule r
            CROSS APPLY (SELECT RankOrder FROM erp_err.Severity WHERE SeverityId = @SeverityId) sv
            OUTER APPLY (SELECT RankOrder AS MinRank FROM erp_err.Severity WHERE SeverityId = r.MinSeverityId) mr
            WHERE r.IsActive = 1
              AND (r.MinSeverityId  IS NULL OR sv.RankOrder <= mr.MinRank)
              AND (r.CategoryId     IS NULL OR r.CategoryId = @CategoryId)
              AND (r.LayerId        IS NULL OR r.LayerId    = @LayerId)
              AND (r.ErpModuleMatch IS NULL OR r.ErpModuleMatch = (SELECT ErpModule FROM @e))
              AND (r.EnvironmentMatch IS NULL OR r.EnvironmentMatch = (SELECT Environment FROM @e))
              AND r.MinOccurrences <= (
                    SELECT COUNT_BIG(*) FROM erp_err.ErrorOccurrence o
                    WHERE o.FingerprintId = @FingerprintId
                      AND o.OccurredUtc >= DATEADD(MINUTE, -r.WindowMinutes, @Now))
            ORDER BY r.MinOccurrences DESC, r.RuleId;

            IF @RuleName IS NOT NULL
            BEGIN
                EXEC erp_err.usp_Ticket_Create
                     @OccurrenceId      = @OccurrenceId,
                     @CreatedVia        = N'auto_rule',
                     @UserDescription   = NULL,
                     @ReportedByUserId  = NULL,
                     @ReportedByUserName= NULL,
                     @QueueId           = @RuleQueueId,
                     @TicketNumber      = @AutoTicketNumber OUTPUT;
            END
        END

        /* ---- what the caller should do next ------------------------------ */
        SELECT @ErrorReference AS ErrorReference,
               @OccurrenceId   AS OccurrenceId,
               @FingerprintId  AS FingerprintId,
               CASE WHEN @IsMuted = 1 THEN CONVERT(BIT,0) ELSE CONVERT(BIT,1) END AS ShouldNotifyUser,
               @AutoTicketNumber AS AutoTicketNumber,
               @IsKnownIssue   AS IsKnownIssue;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        BEGIN TRY
            INSERT erp_err.DeadLetter (Source, RawEnvelopeJson, FailureReason)
            VALUES (@Source, @EnvelopeJson,
                    CONCAT(N'Msg ', ERROR_NUMBER(), N', Line ', ERROR_LINE(), N': ', ERROR_MESSAGE()));
        END TRY
        BEGIN CATCH
            /* Even the dead-letter write failed (disk full, schema gone).
               Swallow: the ERP transaction must survive regardless. */
        END CATCH

        SELECT CONVERT(VARCHAR(24), NULL) AS ErrorReference, CONVERT(BIGINT, NULL) AS OccurrenceId,
               CONVERT(BIGINT, NULL) AS FingerprintId, CONVERT(BIT, 1) AS ShouldNotifyUser,
               CONVERT(VARCHAR(24), NULL) AS AutoTicketNumber, CONVERT(BIT, 0) AS IsKnownIssue;
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
CREATE OR ALTER PROCEDURE erp_err.usp_Ticket_Create
(
    @OccurrenceId       BIGINT,
    @CreatedVia         NVARCHAR(20)   = N'user',
    @UserDescription    NVARCHAR(MAX)  = NULL,
    @ReportedByUserId   NVARCHAR(128)  = NULL,
    @ReportedByUserName NVARCHAR(200)  = NULL,
    @QueueId            SMALLINT       = NULL,
    @TicketNumber       VARCHAR(24)    OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @FingerprintId BIGINT, @SeverityId TINYINT, @ErpModule NVARCHAR(100),
            @Environment NVARCHAR(40), @Message NVARCHAR(2000), @Screen NVARCHAR(200),
            @ExistingTicketId BIGINT, @Now DATETIME2(3) = SYSUTCDATETIME();

    SELECT @FingerprintId = o.FingerprintId, @SeverityId = o.SeverityId,
           @ErpModule = o.ErpModule, @Environment = o.Environment,
           @Message = o.Message, @Screen = o.Screen
    FROM erp_err.ErrorOccurrence o
    WHERE o.OccurrenceId = @OccurrenceId;

    IF @FingerprintId IS NULL
    BEGIN
        SET @TicketNumber = NULL;
        RETURN;
    END

    /* ---- already-open ticket for this problem? ------------------------- */
    SELECT @ExistingTicketId = f.OpenTicketId
    FROM erp_err.ErrorFingerprint f
    WHERE f.FingerprintId = @FingerprintId
      AND f.OpenTicketId IS NOT NULL
      AND EXISTS (SELECT 1 FROM erp_err.Ticket tk
                  JOIN erp_err.TicketStatus st ON st.StatusId = tk.StatusId
                  WHERE tk.TicketId = f.OpenTicketId AND st.IsTerminal = 0);

    IF @ExistingTicketId IS NOT NULL
    BEGIN
        BEGIN TRANSACTION;
            IF NOT EXISTS (SELECT 1 FROM erp_err.TicketOccurrenceLink
                           WHERE TicketId = @ExistingTicketId AND OccurrenceId = @OccurrenceId)
            BEGIN
                INSERT erp_err.TicketOccurrenceLink (TicketId, OccurrenceId, LinkReason)
                VALUES (@ExistingTicketId, @OccurrenceId, N'deduplicated');

                UPDATE erp_err.Ticket
                   SET LinkedOccurrenceCount = LinkedOccurrenceCount + 1
                 WHERE TicketId = @ExistingTicketId;
            END

            UPDATE erp_err.ErrorOccurrence SET TicketId = @ExistingTicketId WHERE OccurrenceId = @OccurrenceId;

            /* The user's own words are still worth keeping - as a comment on
               the existing ticket, not as a duplicate ticket. */
            IF @UserDescription IS NOT NULL AND LEN(LTRIM(RTRIM(@UserDescription))) > 0
                INSERT erp_err.TicketComment (TicketId, AuthorUserId, AuthorUserName, AuthorRole, CommentText, IsCustomerVisible)
                VALUES (@ExistingTicketId, @ReportedByUserId, @ReportedByUserName, N'reporter',
                        CONCAT(N'Additional report (', @OccurrenceId, N'): ', @UserDescription), 1);
        COMMIT TRANSACTION;

        SET @TicketNumber = (SELECT TicketNumber FROM erp_err.Ticket WHERE TicketId = @ExistingTicketId);
        SELECT @TicketNumber AS TicketNumber, @ExistingTicketId AS TicketId, CONVERT(BIT,1) AS WasDeduplicated;
        RETURN;
    END

    /* ---- routing ------------------------------------------------------- */
    IF @QueueId IS NULL
        SELECT TOP 1 @QueueId = QueueId FROM erp_err.TicketQueue
        WHERE IsActive = 1 AND ErpModuleMatch = @ErpModule ORDER BY QueueId;
    IF @QueueId IS NULL
        SELECT TOP 1 @QueueId = QueueId FROM erp_err.TicketQueue
        WHERE IsActive = 1 AND IsDefault = 1 ORDER BY QueueId;
    IF @QueueId IS NULL
        SELECT TOP 1 @QueueId = QueueId FROM erp_err.TicketQueue WHERE IsActive = 1 ORDER BY QueueId;

    DECLARE @SlaPolicyId SMALLINT =
        COALESCE((SELECT TOP 1 SlaPolicyId FROM erp_err.SlaPolicy
                  WHERE IsActive = 1 AND SeverityId = @SeverityId AND QueueId = @QueueId),
                 (SELECT TOP 1 SlaPolicyId FROM erp_err.SlaPolicy
                  WHERE IsActive = 1 AND SeverityId = @SeverityId AND QueueId IS NULL));

    DECLARE @NewTicketId BIGINT;
    SET @TicketNumber = erp_err.fn_FormatReference('TKT', NEXT VALUE FOR erp_err.TicketNumberSeq, @Now);

    DECLARE @Title NVARCHAR(400) =
        LEFT(CONCAT(ISNULL(@ErpModule, N'ERP'), N' / ', ISNULL(@Screen, N'(unknown screen)'), N' - ',
                    ISNULL(@Message, N'Unexpected error')), 400);

    BEGIN TRANSACTION;
        INSERT erp_err.Ticket
        (
            TicketNumber, OccurrenceId, FingerprintId, StatusId, SeverityId, QueueId, SlaPolicyId,
            Title, UserDescription, ReportedByUserId, ReportedByUserName, CreatedVia,
            ErpModule, Environment, CreatedUtc, LastStatusChangeUtc, LinkedOccurrenceCount
        )
        VALUES
        (
            @TicketNumber, @OccurrenceId, @FingerprintId, 1 /*new*/, @SeverityId, @QueueId, @SlaPolicyId,
            @Title, @UserDescription, @ReportedByUserId, @ReportedByUserName, @CreatedVia,
            @ErpModule, @Environment, @Now, @Now, 1
        );

        SET @NewTicketId = SCOPE_IDENTITY();

        INSERT erp_err.TicketStatusHistory
            (TicketId, SequenceNo, FromStatusId, ToStatusId, ChangedByUserId, ChangedByUserName,
             ChangedUtc, MinutesInFromStatus, Comments, IsCustomerVisible)
        VALUES
            (@NewTicketId, 1, NULL, 1, @ReportedByUserId, @ReportedByUserName, @Now, NULL,
             CASE WHEN @CreatedVia = N'auto_rule'
                  THEN N'Ticket raised automatically by an error-management rule.'
                  ELSE N'Ticket raised by the user from the error dialog.' END, 1);

        INSERT erp_err.TicketOccurrenceLink (TicketId, OccurrenceId, LinkReason)
        VALUES (@NewTicketId, @OccurrenceId, N'primary');

        UPDATE erp_err.ErrorOccurrence SET TicketId = @NewTicketId WHERE OccurrenceId = @OccurrenceId;

        UPDATE erp_err.ErrorFingerprint
           SET OpenTicketId = @NewTicketId,
               TriageState  = CASE WHEN TriageState = N'new' THEN N'acknowledged' ELSE TriageState END
         WHERE FingerprintId = @FingerprintId;
    COMMIT TRANSACTION;

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
CREATE OR ALTER PROCEDURE erp_err.usp_Ticket_ChangeStatus
(
    @TicketId           BIGINT,
    @ToStatusId         TINYINT,
    @ChangedByUserId    NVARCHAR(128) = NULL,
    @ChangedByUserName  NVARCHAR(200) = NULL,
    @Comments           NVARCHAR(MAX) = NULL,
    @AssignToUserId     NVARCHAR(128) = NULL,
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
    DECLARE @FromStatusId TINYINT, @LastChangeUtc DATETIME2(3), @CreatedUtc DATETIME2(3),
            @FingerprintId BIGINT, @SeqNo INT, @FromIsPaused BIT, @ToIsTerminal BIT,
            @ToIsOpen BIT, @FirstResponseUtc DATETIME2(3);

    SELECT @FromStatusId   = t.StatusId,
           @LastChangeUtc  = t.LastStatusChangeUtc,
           @CreatedUtc     = t.CreatedUtc,
           @FingerprintId  = t.FingerprintId,
           @FirstResponseUtc = t.FirstResponseUtc
    FROM erp_err.Ticket t WHERE t.TicketId = @TicketId;

    IF @FromStatusId IS NULL
    BEGIN
        RAISERROR (N'Ticket %I64d does not exist.', 16, 1, @TicketId);
        RETURN;
    END

    IF @FromStatusId = @ToStatusId
    BEGIN
        RAISERROR (N'Ticket is already in that status.', 16, 1);
        RETURN;
    END

    /* ---- is this move legal in the configured workflow? ---------------- */
    DECLARE @RequiresComment BIT, @RequiresAssignee BIT;
    SELECT @RequiresComment = RequiresComment, @RequiresAssignee = RequiresAssignee
    FROM erp_err.TicketStatusTransition
    WHERE FromStatusId = @FromStatusId AND ToStatusId = @ToStatusId AND IsActive = 1;

    IF @RequiresComment IS NULL
    BEGIN
        DECLARE @fromName NVARCHAR(80) = (SELECT DisplayName FROM erp_err.TicketStatus WHERE StatusId = @FromStatusId);
        DECLARE @toName   NVARCHAR(80) = (SELECT DisplayName FROM erp_err.TicketStatus WHERE StatusId = @ToStatusId);
        RAISERROR (N'Transition "%s" -> "%s" is not permitted by the configured workflow.', 16, 1, @fromName, @toName);
        RETURN;
    END

    IF @RequiresComment = 1 AND (@Comments IS NULL OR LEN(LTRIM(RTRIM(@Comments))) = 0)
    BEGIN
        RAISERROR (N'This status change requires a comment.', 16, 1);
        RETURN;
    END

    DECLARE @EffectiveAssigneeId NVARCHAR(128) =
        COALESCE(@AssignToUserId, (SELECT AssignedToUserId FROM erp_err.Ticket WHERE TicketId = @TicketId));

    IF @RequiresAssignee = 1 AND @EffectiveAssigneeId IS NULL
    BEGIN
        RAISERROR (N'This status change requires the ticket to be assigned.', 16, 1);
        RETURN;
    END

    SELECT @FromIsPaused = IsPaused FROM erp_err.TicketStatus WHERE StatusId = @FromStatusId;
    SELECT @ToIsTerminal = IsTerminal, @ToIsOpen = IsOpen FROM erp_err.TicketStatus WHERE StatusId = @ToStatusId;

    DECLARE @MinutesInFrom INT = DATEDIFF(MINUTE, @LastChangeUtc, @Now);

    BEGIN TRANSACTION;

        SELECT @SeqNo = ISNULL(MAX(SequenceNo), 0) + 1
        FROM erp_err.TicketStatusHistory WITH (UPDLOCK, HOLDLOCK)
        WHERE TicketId = @TicketId;

        INSERT erp_err.TicketStatusHistory
            (TicketId, SequenceNo, FromStatusId, ToStatusId, ChangedByUserId, ChangedByUserName,
             ChangedUtc, MinutesInFromStatus, Comments, IsCustomerVisible)
        VALUES
            (@TicketId, @SeqNo, @FromStatusId, @ToStatusId, @ChangedByUserId, @ChangedByUserName,
             @Now, @MinutesInFrom, @Comments, @IsCustomerVisible);

        UPDATE t
           SET t.StatusId            = @ToStatusId,
               t.LastStatusChangeUtc = @Now,

               /* First response: the first time anybody who is not the reporter
                  acts on the ticket.  Set once, never overwritten. */
               t.FirstResponseUtc = COALESCE(t.FirstResponseUtc,
                                        CASE WHEN @ChangedByUserId IS NULL
                                               OR @ChangedByUserId <> ISNULL(t.ReportedByUserId, N'~')
                                             THEN @Now END),

               t.AssignedUtc      = CASE WHEN @ToStatusId = 2 AND t.AssignedUtc IS NULL THEN @Now ELSE t.AssignedUtc END,
               t.ResolvedUtc      = CASE WHEN @ToStatusId = 5 THEN @Now
                                         WHEN @ToStatusId = 8 THEN NULL   -- reopened: clear it
                                         ELSE t.ResolvedUtc END,
               t.ClosedUtc        = CASE WHEN @ToIsTerminal = 1 THEN @Now
                                         WHEN @ToStatusId = 8 THEN NULL
                                         ELSE t.ClosedUtc END,

               t.AssignedToUserId   = COALESCE(@AssignToUserId, t.AssignedToUserId),
               t.AssignedToUserName = COALESCE(@AssignToUserName, t.AssignedToUserName),

               t.ReopenCount      = t.ReopenCount + CASE WHEN @ToStatusId = 8 THEN 1 ELSE 0 END,

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
                            FROM erp_err.TicketStatusHistory h
                            JOIN erp_err.TicketStatus s ON s.StatusId = h.FromStatusId
                            WHERE h.TicketId = @TicketId AND s.IsPaused = 1), 0)
                  - CASE WHEN @FromIsPaused = 1 THEN @MinutesInFrom ELSE 0 END
          FROM erp_err.Ticket t
         WHERE t.TicketId = @TicketId;

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
          FROM erp_err.Ticket t
          JOIN erp_err.SlaPolicy p ON p.SlaPolicyId = t.SlaPolicyId
         WHERE t.TicketId = @TicketId;

        /* The problem stops pointing at this ticket once it is closed, so a
           future occurrence opens a fresh one instead of reviving a dead ticket. */
        IF @ToIsTerminal = 1
            UPDATE erp_err.ErrorFingerprint
               SET OpenTicketId = NULL,
                   TriageState  = CASE WHEN TriageState IN (N'new', N'acknowledged') THEN N'resolved' ELSE TriageState END
             WHERE FingerprintId = @FingerprintId AND OpenTicketId = @TicketId;
        ELSE IF @ToStatusId = 8   -- reopened
            UPDATE erp_err.ErrorFingerprint
               SET OpenTicketId = @TicketId, TriageState = N'acknowledged'
             WHERE FingerprintId = @FingerprintId;

    COMMIT TRANSACTION;

    SELECT @TicketId AS TicketId, @FromStatusId AS FromStatusId, @ToStatusId AS ToStatusId,
           @SeqNo AS SequenceNo, @MinutesInFrom AS MinutesInPreviousStatus;
END
GO

/* =============================================================================
   usp_Ticket_AddComment
   ============================================================================= */
CREATE OR ALTER PROCEDURE erp_err.usp_Ticket_AddComment
(
    @TicketId           BIGINT,
    @AuthorUserId       NVARCHAR(128) = NULL,
    @AuthorUserName     NVARCHAR(200) = NULL,
    @AuthorRole         NVARCHAR(20)  = N'support',
    @CommentText        NVARCHAR(MAX),
    @IsCustomerVisible  BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM erp_err.Ticket WHERE TicketId = @TicketId)
    BEGIN
        RAISERROR (N'Ticket %I64d does not exist.', 16, 1, @TicketId);
        RETURN;
    END

    INSERT erp_err.TicketComment (TicketId, AuthorUserId, AuthorUserName, AuthorRole, CommentText, IsCustomerVisible)
    VALUES (@TicketId, @AuthorUserId, @AuthorUserName, @AuthorRole, @CommentText, @IsCustomerVisible);

    /* A support reply counts as the first response even without a status move. */
    IF @AuthorRole = N'support'
        UPDATE erp_err.Ticket
           SET FirstResponseUtc = ISNULL(FirstResponseUtc, SYSUTCDATETIME())
         WHERE TicketId = @TicketId;

    SELECT SCOPE_IDENTITY() AS CommentId;
END
GO

/* =============================================================================
   Search / reporting procedures
   ============================================================================= */
CREATE OR ALTER PROCEDURE erp_err.usp_Error_Search
(
    @ErrorReference VARCHAR(24)   = NULL,
    @TicketNumber   VARCHAR(24)   = NULL,
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
    @CorrelationId  UNIQUEIDENTIFIER = NULL,
    @FingerprintId  BIGINT        = NULL,
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
    IF @FromUtc IS NULL AND @ErrorReference IS NULL AND @TicketNumber IS NULL AND @CorrelationId IS NULL
        SET @FromUtc = DATEADD(DAY, -30, SYSUTCDATETIME());

    SELECT
        o.OccurrenceId, o.ErrorReference, o.OccurredUtc, o.OccurredLocal,
        l.Code AS LayerCode, l.DisplayName AS LayerName,
        c.Code AS CategoryCode, c.DisplayName AS CategoryName,
        sv.Code AS SeverityCode, sv.DisplayName AS SeverityName, sv.RankOrder AS SeverityRank,
        o.ExceptionType, o.Message,
        o.ErpModule, o.Screen, o.Component, o.RouteUrl, o.ActionName, o.FormName, o.LovName,
        o.ApiApplication, o.ApiController, o.ApiAction, o.ApiEndpoint, o.HttpMethod, o.HttpStatusCode,
        o.SqlErrorNumber, o.SqlObjectName, o.SqlLineNumber,
        o.UserName, o.UserDisplayName, o.Environment, o.AppVersion,
        o.BrowserName, o.BrowserVersion, o.OsName,
        o.CorrelationId, o.RequestId,
        o.FingerprintId, f.FingerprintHash, f.OccurrenceCount AS FingerprintOccurrenceCount,
        f.DistinctUserCount, f.FirstSeenUtc, f.LastSeenUtc, f.TriageState,
        o.TicketId, tk.TicketNumber, ts.Code AS TicketStatusCode, ts.DisplayName AS TicketStatusName,
        COUNT(*) OVER () AS TotalRowCount
    FROM erp_err.ErrorOccurrence o
    JOIN erp_err.ErrorFingerprint f ON f.FingerprintId = o.FingerprintId
    JOIN erp_err.AppLayer       l  ON l.LayerId    = o.LayerId
    JOIN erp_err.ErrorCategory  c  ON c.CategoryId = o.CategoryId
    JOIN erp_err.Severity       sv ON sv.SeverityId = o.SeverityId
    LEFT JOIN erp_err.Ticket        tk ON tk.TicketId = o.TicketId
    LEFT JOIN erp_err.TicketStatus  ts ON ts.StatusId = tk.StatusId
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
      AND (@CorrelationId  IS NULL OR o.CorrelationId = @CorrelationId)
      AND (@FingerprintId  IS NULL OR o.FingerprintId = @FingerprintId)
      AND (@FromUtc        IS NULL OR o.OccurredUtc  >= @FromUtc)
      AND (@ToUtc          IS NULL OR o.OccurredUtc  <= @ToUtc)
      AND (@MinOccurrences IS NULL OR f.OccurrenceCount >= @MinOccurrences)
      AND (@SearchText     IS NULL OR o.Message LIKE N'%' + @SearchText + N'%'
                                   OR o.ExceptionType LIKE N'%' + @SearchText + N'%'
                                   OR o.Screen LIKE N'%' + @SearchText + N'%')
    ORDER BY o.OccurredUtc DESC, o.OccurrenceId DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);   -- widely varying predicates; a cached plan here is a trap
END
GO

/* Recurring-problem report: the "frequently occurring problems that should be
   permanently resolved" list the brief asked for.                             */
CREATE OR ALTER PROCEDURE erp_err.usp_Error_RecurringProblems
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
        f.FingerprintId, f.FingerprintHash, f.SignatureText,
        sv.Code AS SeverityCode, sv.DisplayName AS SeverityName,
        c.Code  AS CategoryCode, l.Code AS LayerCode,
        f.ExceptionType, f.NormalizedMessage,
        f.ErpModule, f.Screen, f.Component, f.ApiEndpoint, f.SqlObjectName,
        f.FirstSeenUtc, f.LastSeenUtc, f.TriageState,
        f.OccurrenceCount AS LifetimeOccurrences,
        w.WindowOccurrences, w.WindowDistinctUsers,
        f.OpenTicketId, tk.TicketNumber AS OpenTicketNumber
    FROM erp_err.ErrorFingerprint f
    JOIN erp_err.Severity      sv ON sv.SeverityId = f.SeverityId
    JOIN erp_err.ErrorCategory c  ON c.CategoryId  = f.CategoryId
    JOIN erp_err.AppLayer      l  ON l.LayerId     = f.LayerId
    LEFT JOIN erp_err.Ticket   tk ON tk.TicketId   = f.OpenTicketId
    CROSS APPLY (
        SELECT COUNT_BIG(*) AS WindowOccurrences, COUNT(DISTINCT o.UserName) AS WindowDistinctUsers
        FROM erp_err.ErrorOccurrence o
        WHERE o.FingerprintId = f.FingerprintId AND o.OccurredUtc >= @FromUtc
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
CREATE OR ALTER PROCEDURE erp_err.usp_Error_GetCorrelationTrail
(
    @CorrelationId UNIQUEIDENTIFIER
)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT o.OccurrenceId, o.ErrorReference, o.OccurredUtc, o.ReceivedUtc,
           l.Code AS LayerCode, l.DisplayName AS LayerName, l.LayerId,
           c.Code AS CategoryCode, sv.Code AS SeverityCode,
           o.ExceptionType, o.Message,
           o.Component, o.Screen, o.ApiController, o.ApiAction, o.HttpStatusCode,
           o.SqlErrorNumber, o.SqlObjectName, o.SqlLineNumber,
           o.ParentOccurrenceId, o.RequestId,
           d.StackTrace, d.InnerExceptionChain, d.SqlStatementText
    FROM erp_err.ErrorOccurrence o
    JOIN erp_err.AppLayer      l  ON l.LayerId     = o.LayerId
    JOIN erp_err.ErrorCategory c  ON c.CategoryId  = o.CategoryId
    JOIN erp_err.Severity      sv ON sv.SeverityId = o.SeverityId
    LEFT JOIN erp_err.ErrorOccurrenceDetail d ON d.OccurrenceId = o.OccurrenceId
    WHERE o.CorrelationId = @CorrelationId
    ORDER BY l.LayerId DESC, o.OccurredUtc ASC;   -- deepest layer first: the cause, then the symptom
END
GO

CREATE OR ALTER PROCEDURE erp_err.usp_Ticket_Search
(
    @TicketNumber   VARCHAR(24)   = NULL,
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
        t.TicketId, t.TicketNumber, t.Title, t.CreatedVia,
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
                            FROM erp_err.TicketStatusHistory h
                            JOIN erp_err.TicketStatus s2 ON s2.StatusId = h.FromStatusId
                            WHERE h.TicketId = t.TicketId AND s2.IsPaused = 1), 0)
                  - CASE WHEN st.IsPaused = 1 THEN DATEDIFF(MINUTE, t.LastStatusChangeUtc, SYSUTCDATETIME()) ELSE 0 END
        END AS ActiveProcessingMinutes,
        t.SlaFirstResponseBreached, t.SlaResolutionBreached,
        p.FirstResponseMinutes AS SlaFirstResponseTargetMinutes,
        p.ResolutionMinutes    AS SlaResolutionTargetMinutes,
        t.ReopenCount, t.LinkedOccurrenceCount,
        t.FingerprintId, o.ErrorReference AS PrimaryErrorReference,
        COUNT(*) OVER () AS TotalRowCount
    FROM erp_err.Ticket t
    JOIN erp_err.TicketStatus st ON st.StatusId = t.StatusId
    JOIN erp_err.Severity     sv ON sv.SeverityId = t.SeverityId
    JOIN erp_err.TicketQueue  q  ON q.QueueId     = t.QueueId
    LEFT JOIN erp_err.SlaPolicy p ON p.SlaPolicyId = t.SlaPolicyId
    LEFT JOIN erp_err.ErrorOccurrence o ON o.OccurrenceId = t.OccurrenceId
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
CREATE OR ALTER PROCEDURE erp_err.usp_Ticket_GetDetail
(
    @TicketNumber VARCHAR(24),
    @ForEndUser   BIT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TicketId BIGINT = (SELECT TicketId FROM erp_err.Ticket WHERE TicketNumber = @TicketNumber);
    IF @TicketId IS NULL RETURN;

    /* 1: header */
    SELECT t.TicketId, t.TicketNumber, t.Title,
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
                               FROM erp_err.TicketStatusHistory h
                               JOIN erp_err.TicketStatus s2 ON s2.StatusId = h.FromStatusId
                               WHERE h.TicketId = t.TicketId AND s2.IsPaused = 1), 0)
                     - CASE WHEN st.IsPaused = 1
                            THEN DATEDIFF(MINUTE, t.LastStatusChangeUtc, SYSUTCDATETIME())
                            ELSE 0 END
           END AS ActiveProcessingMinutes,
           t.SlaFirstResponseBreached, t.SlaResolutionBreached,
           t.ReopenCount, t.LinkedOccurrenceCount,
           t.ResolutionCode, t.ResolutionNotes,
           o.ErrorReference AS PrimaryErrorReference,
           CASE WHEN @ForEndUser = 1 THEN NULL ELSE t.FingerprintId END AS FingerprintId
    FROM erp_err.Ticket t
    JOIN erp_err.TicketStatus st ON st.StatusId = t.StatusId
    JOIN erp_err.Severity     sv ON sv.SeverityId = t.SeverityId
    JOIN erp_err.TicketQueue  q  ON q.QueueId = t.QueueId
    LEFT JOIN erp_err.ErrorOccurrence o ON o.OccurrenceId = t.OccurrenceId
    WHERE t.TicketId = @TicketId;

    /* 2: status history - the audit trail */
    SELECT h.SequenceNo,
           fs.Code AS FromStatusCode, fs.DisplayName AS FromStatusName,
           ts.Code AS ToStatusCode,   ts.DisplayName AS ToStatusName,
           CASE WHEN @ForEndUser = 1 THEN NULL ELSE h.ChangedByUserName END AS ChangedByUserName,
           h.ChangedUtc, h.MinutesInFromStatus, h.Comments
    FROM erp_err.TicketStatusHistory h
    LEFT JOIN erp_err.TicketStatus fs ON fs.StatusId = h.FromStatusId
    JOIN erp_err.TicketStatus ts      ON ts.StatusId = h.ToStatusId
    WHERE h.TicketId = @TicketId
      AND (@ForEndUser = 0 OR h.IsCustomerVisible = 1)
    ORDER BY h.SequenceNo;

    /* 3: comments */
    SELECT c.CommentId, c.AuthorUserName, c.AuthorRole, c.CommentText, c.CreatedUtc
    FROM erp_err.TicketComment c
    WHERE c.TicketId = @TicketId
      AND (@ForEndUser = 0 OR c.IsCustomerVisible = 1)
    ORDER BY c.CreatedUtc;

    /* 4: time in each status - the operational metric, derived from history */
    SELECT s.Code AS StatusCode, s.DisplayName AS StatusName,
           SUM(h.MinutesInFromStatus) AS MinutesInStatus,
           COUNT(*) AS TimesEntered
    FROM erp_err.TicketStatusHistory h
    JOIN erp_err.TicketStatus s ON s.StatusId = h.FromStatusId
    WHERE h.TicketId = @TicketId AND h.MinutesInFromStatus IS NOT NULL
    GROUP BY s.Code, s.DisplayName, s.RankOrder
    ORDER BY s.RankOrder;

    /* 5: linked occurrences - admin only */
    IF @ForEndUser = 0
        SELECT TOP 200 o.OccurrenceId, o.ErrorReference, o.OccurredUtc, o.UserName,
               o.Screen, o.Component, o.Message, li.LinkReason
        FROM erp_err.TicketOccurrenceLink li
        JOIN erp_err.ErrorOccurrence o ON o.OccurrenceId = li.OccurrenceId
        WHERE li.TicketId = @TicketId
        ORDER BY o.OccurredUtc DESC;
END
GO

/* Full diagnostic payload for one occurrence.  Admin only - the end user's
   modal never calls this.                                                     */
CREATE OR ALTER PROCEDURE erp_err.usp_Error_GetDetail
(
    @ErrorReference VARCHAR(24)
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
    FROM erp_err.ErrorOccurrence o
    JOIN erp_err.AppLayer      l  ON l.LayerId     = o.LayerId
    JOIN erp_err.ErrorCategory c  ON c.CategoryId  = o.CategoryId
    JOIN erp_err.Severity      sv ON sv.SeverityId = o.SeverityId
    JOIN erp_err.ErrorFingerprint f ON f.FingerprintId = o.FingerprintId
    LEFT JOIN erp_err.ErrorOccurrenceDetail d ON d.OccurrenceId = o.OccurrenceId
    LEFT JOIN erp_err.Ticket tk ON tk.TicketId = o.TicketId
    WHERE o.ErrorReference = @ErrorReference;
END
GO

/* Dashboard counters for the admin landing page. */
CREATE OR ALTER PROCEDURE erp_err.usp_Dashboard_Summary
(
    @FromUtc DATETIME2(3) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromUtc IS NULL SET @FromUtc = DATEADD(DAY, -7, SYSUTCDATETIME());

    SELECT
        (SELECT COUNT_BIG(*) FROM erp_err.ErrorOccurrence WHERE OccurredUtc >= @FromUtc)       AS ErrorsInPeriod,
        (SELECT COUNT_BIG(*) FROM erp_err.ErrorFingerprint WHERE LastSeenUtc >= @FromUtc)      AS DistinctProblemsInPeriod,
        (SELECT COUNT_BIG(*) FROM erp_err.Ticket t JOIN erp_err.TicketStatus s ON s.StatusId = t.StatusId
          WHERE s.IsOpen = 1)                                                                  AS OpenTickets,
        (SELECT COUNT_BIG(*) FROM erp_err.Ticket t JOIN erp_err.TicketStatus s ON s.StatusId = t.StatusId
          WHERE s.IsOpen = 1 AND (t.SlaFirstResponseBreached = 1 OR t.SlaResolutionBreached = 1)) AS OpenTicketsBreachingSla,
        (SELECT COUNT_BIG(*) FROM erp_err.Ticket WHERE CreatedUtc >= @FromUtc)                 AS TicketsCreatedInPeriod,
        (SELECT COUNT_BIG(*) FROM erp_err.DeadLetter WHERE ReceivedUtc >= @FromUtc)            AS CaptureFailuresInPeriod;

    /* Errors by layer */
    SELECT l.Code AS LayerCode, l.DisplayName AS LayerName, COUNT_BIG(*) AS ErrorCount
    FROM erp_err.ErrorOccurrence o JOIN erp_err.AppLayer l ON l.LayerId = o.LayerId
    WHERE o.OccurredUtc >= @FromUtc
    GROUP BY l.Code, l.DisplayName, l.LayerId ORDER BY l.LayerId;

    /* Errors by severity */
    SELECT sv.Code AS SeverityCode, sv.DisplayName AS SeverityName, COUNT_BIG(*) AS ErrorCount
    FROM erp_err.ErrorOccurrence o JOIN erp_err.Severity sv ON sv.SeverityId = o.SeverityId
    WHERE o.OccurredUtc >= @FromUtc
    GROUP BY sv.Code, sv.DisplayName, sv.RankOrder ORDER BY sv.RankOrder;

    /* Top modules */
    SELECT TOP 10 ISNULL(o.ErpModule, N'(unknown)') AS ErpModule, COUNT_BIG(*) AS ErrorCount
    FROM erp_err.ErrorOccurrence o WHERE o.OccurredUtc >= @FromUtc
    GROUP BY o.ErpModule ORDER BY COUNT_BIG(*) DESC;
END
GO

/* Triage a problem: acknowledge, mark as known, mute the noise, add a note. */
CREATE OR ALTER PROCEDURE erp_err.usp_Fingerprint_Triage
(
    @FingerprintId  BIGINT,
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
        (SELECT TriageState, MutedUntilUtc, Notes FROM erp_err.ErrorFingerprint
         WHERE FingerprintId = @FingerprintId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    UPDATE erp_err.ErrorFingerprint
       SET TriageState   = COALESCE(@TriageState, TriageState),
           MutedUntilUtc = CASE WHEN @MuteMinutes IS NULL THEN MutedUntilUtc
                                WHEN @MuteMinutes <= 0 THEN NULL
                                ELSE DATEADD(MINUTE, @MuteMinutes, SYSUTCDATETIME()) END,
           Notes         = COALESCE(@Notes, Notes)
     WHERE FingerprintId = @FingerprintId;

    INSERT erp_err.ConfigAudit (TableName, KeyValue, Operation, OldValuesJson, NewValuesJson, ChangedByUserName)
    SELECT N'ErrorFingerprint', CONVERT(NVARCHAR(200), @FingerprintId), 'UPDATE', @OldJson,
           (SELECT TriageState, MutedUntilUtc, Notes FROM erp_err.ErrorFingerprint
            WHERE FingerprintId = @FingerprintId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           @ChangedByUserName;
END
GO

/* What a given user is allowed to see about their own tickets. */
CREATE OR ALTER PROCEDURE erp_err.usp_Ticket_ListForUser
(
    @UserId     NVARCHAR(128) = NULL,
    @UserName   NVARCHAR(200) = NULL,
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

    IF @UserId IS NULL AND @UserName IS NULL RETURN;

    SELECT t.TicketNumber, t.Title,
           st.Code AS StatusCode, st.DisplayName AS StatusName, st.IsOpen,
           sv.DisplayName AS SeverityName,
           t.CreatedUtc, t.ResolvedUtc, t.ClosedUtc,
           t.ErpModule,
           (SELECT TOP 1 h.Comments FROM erp_err.TicketStatusHistory h
            WHERE h.TicketId = t.TicketId AND h.IsCustomerVisible = 1
            ORDER BY h.SequenceNo DESC) AS LatestUpdate,
           COUNT(*) OVER () AS TotalRowCount
    FROM erp_err.Ticket t
    JOIN erp_err.TicketStatus st ON st.StatusId = t.StatusId
    JOIN erp_err.Severity     sv ON sv.SeverityId = t.SeverityId
    WHERE ((@UserId   IS NOT NULL AND t.ReportedByUserId   = @UserId)
        OR (@UserName IS NOT NULL AND t.ReportedByUserName = @UserName))
      AND (@OnlyOpen = 0 OR st.IsOpen = 1)
    ORDER BY t.CreatedUtc DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

/* Configuration read by the API at startup / on cache expiry. */
CREATE OR ALTER PROCEDURE erp_err.usp_Config_Get
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SettingKey, SettingValue, DataType FROM erp_err.Setting;
    SELECT Scope, KeyName FROM erp_err.RedactionAllowList WHERE IsActive = 1;
    SELECT SeverityId, Code, DisplayName, RankOrder FROM erp_err.Severity WHERE IsActive = 1;
    SELECT CategoryId, Code, DisplayName, DefaultSeverityId FROM erp_err.ErrorCategory WHERE IsActive = 1;
    SELECT LayerId, Code, DisplayName FROM erp_err.AppLayer;
    SELECT StatusId, Code, DisplayName, RankOrder, IsOpen, IsTerminal, IsPaused
      FROM erp_err.TicketStatus WHERE IsActive = 1;
    SELECT FromStatusId, ToStatusId, RequiresComment, RequiresAssignee
      FROM erp_err.TicketStatusTransition WHERE IsActive = 1;
    SELECT QueueId, Code, DisplayName, ErpModuleMatch, IsDefault FROM erp_err.TicketQueue WHERE IsActive = 1;
END
GO

MERGE erp_err.SchemaVersion AS t
USING (SELECT N'004_programmability.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion) VALUES (s.ScriptName, N'1.0.0');
GO
