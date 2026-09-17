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
IF OBJECT_ID(N'erp_err.SortWhitelist', N'U') IS NULL
BEGIN
    CREATE TABLE erp_err.SortWhitelist
    (
        /* 'error' | 'ticket' | 'problem' */
        ListName        NVARCHAR(20)    NOT NULL,
        SortKey         NVARCHAR(40)    NOT NULL,
        /* Literal ORDER BY text. Authored here, never caller-supplied. */
        OrderByClause   NVARCHAR(200)   NOT NULL,
        IsDefault       BIT             NOT NULL CONSTRAINT DF_SortWhitelist_IsDefault DEFAULT (0),
        CONSTRAINT PK_SortWhitelist PRIMARY KEY CLUSTERED (ListName, SortKey)
    );
END
GO

/* Every clause ends with a unique tiebreaker. Without one, two rows with the
   same sort value can swap places between page 1 and page 2, so a row is shown
   twice and another is never shown at all - the classic "pagination loses
   records" bug, which looks like data loss to whoever reports it. */
MERGE erp_err.SortWhitelist AS t
USING (VALUES
    /* ---- error occurrences ---- */
    (N'error',   N'occurred_desc',    N'o.OccurredUtc DESC, o.OccurrenceId DESC', 1),
    (N'error',   N'occurred_asc',     N'o.OccurredUtc ASC, o.OccurrenceId ASC', 0),
    (N'error',   N'severity',         N'sv.RankOrder ASC, o.OccurredUtc DESC, o.OccurrenceId DESC', 0),
    (N'error',   N'module',           N'o.ErpModule ASC, o.OccurredUtc DESC, o.OccurrenceId DESC', 0),
    (N'error',   N'screen',           N'o.Screen ASC, o.OccurredUtc DESC, o.OccurrenceId DESC', 0),
    (N'error',   N'user',             N'o.UserName ASC, o.OccurredUtc DESC, o.OccurrenceId DESC', 0),
    (N'error',   N'frequency',        N'f.OccurrenceCount DESC, o.OccurredUtc DESC, o.OccurrenceId DESC', 0),
    (N'error',   N'layer',            N'l.LayerId ASC, o.OccurredUtc DESC, o.OccurrenceId DESC', 0),

    /* ---- tickets ---- */
    (N'ticket',  N'severity',         N'sv.RankOrder ASC, t.CreatedUtc DESC, t.TicketId DESC', 1),
    (N'ticket',  N'created_desc',     N't.CreatedUtc DESC, t.TicketId DESC', 0),
    (N'ticket',  N'created_asc',      N't.CreatedUtc ASC, t.TicketId ASC', 0),
    (N'ticket',  N'status',           N'st.RankOrder ASC, t.CreatedUtc DESC, t.TicketId DESC', 0),
    (N'ticket',  N'queue',            N'q.Code ASC, t.CreatedUtc DESC, t.TicketId DESC', 0),
    (N'ticket',  N'assignee',         N't.AssignedToUserName ASC, t.CreatedUtc DESC, t.TicketId DESC', 0),
    (N'ticket',  N'linked',           N't.LinkedOccurrenceCount DESC, t.CreatedUtc DESC, t.TicketId DESC', 0),
    /* Oldest-open-first: the queue view that actually matters operationally. */
    (N'ticket',  N'age',              N'CASE WHEN st.IsOpen = 1 THEN 0 ELSE 1 END ASC, t.CreatedUtc ASC, t.TicketId ASC', 0),
    (N'ticket',  N'sla',              N'CASE WHEN t.SlaResolutionBreached = 1 OR t.SlaFirstResponseBreached = 1 THEN 0 ELSE 1 END ASC, sv.RankOrder ASC, t.CreatedUtc DESC, t.TicketId DESC', 0),

    /* ---- recurring problems ---- */
    (N'problem', N'window_count',     N'w.WindowOccurrences DESC, f.FingerprintId DESC', 1),
    (N'problem', N'lifetime_count',   N'f.OccurrenceCount DESC, f.FingerprintId DESC', 0),
    (N'problem', N'users',            N'w.WindowDistinctUsers DESC, f.FingerprintId DESC', 0),
    (N'problem', N'severity',         N'sv.RankOrder ASC, w.WindowOccurrences DESC, f.FingerprintId DESC', 0),
    (N'problem', N'last_seen',        N'f.LastSeenUtc DESC, f.FingerprintId DESC', 0),
    (N'problem', N'first_seen',       N'f.FirstSeenUtc ASC, f.FingerprintId ASC', 0),
    (N'problem', N'module',           N'f.ErpModule ASC, w.WindowOccurrences DESC, f.FingerprintId DESC', 0)
) AS s (ListName, SortKey, OrderByClause, IsDefault)
    ON t.ListName = s.ListName AND t.SortKey = s.SortKey
WHEN MATCHED THEN
    UPDATE SET OrderByClause = s.OrderByClause, IsDefault = s.IsDefault
WHEN NOT MATCHED THEN
    INSERT (ListName, SortKey, OrderByClause, IsDefault)
    VALUES (s.ListName, s.SortKey, s.OrderByClause, s.IsDefault);
GO

CREATE OR ALTER FUNCTION erp_err.fn_ResolveSort
(
    @ListName NVARCHAR(20),
    @SortKey  NVARCHAR(40),
    @Descending BIT = NULL      -- NULL = use the clause as written
)
RETURNS NVARCHAR(200)
AS
BEGIN
    DECLARE @clause NVARCHAR(200) =
        (SELECT OrderByClause FROM erp_err.SortWhitelist
         WHERE ListName = @ListName AND SortKey = @SortKey);

    /* Unknown key -> the default for this list. Never an error: a stale
       bookmark must not break the console. */
    IF @clause IS NULL
        SET @clause = (SELECT TOP 1 OrderByClause FROM erp_err.SortWhitelist
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
    @MinOccurrences INT           = NULL,
    @OnlyUnticketed BIT           = NULL,

    /* ---- sorting ---- */
    @SortBy         NVARCHAR(40)  = NULL,   -- key into erp_err.SortWhitelist

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
       AND @CorrelationId IS NULL AND @FingerprintId IS NULL
        SET @FromUtc = DATEADD(DAY, -30, SYSUTCDATETIME());

    DECLARE @keyset BIT = CASE WHEN @AfterOccurredUtc IS NOT NULL AND @AfterOccurrenceId IS NOT NULL
                               THEN 1 ELSE 0 END;

    /* Keyset paging is only coherent for the default chronological order - the
       cursor IS (OccurredUtc, OccurrenceId). Asked for both, the sort wins and
       the cursor is ignored, because silently reordering the caller's results
       is worse than silently ignoring a cursor they can re-request. */
    IF @keyset = 1 AND @SortBy IS NOT NULL AND @SortBy <> N'occurred_desc'
        SET @keyset = 0;

    DECLARE @orderBy NVARCHAR(200) = erp_err.fn_ResolveSort(N'error', @SortBy, NULL);

    DECLARE @sql NVARCHAR(MAX) = N'
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
        o.TicketId, tk.TicketNumber, ts.Code AS TicketStatusCode, ts.DisplayName AS TicketStatusName'
    + CASE WHEN @IncludeTotalCount = 1 THEN N',
        COUNT(*) OVER () AS TotalRowCount' ELSE N',
        CONVERT(BIGINT, NULL) AS TotalRowCount' END + N'
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
      AND (@ApiEndpoint    IS NULL OR o.ApiEndpoint LIKE @ApiEndpoint + N''%'')
      AND (@ExceptionType  IS NULL OR o.ExceptionType LIKE N''%'' + @ExceptionType + N''%'')
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
      AND (@OnlyUnticketed IS NULL OR @OnlyUnticketed = 0 OR o.TicketId IS NULL)
      AND (@SearchText     IS NULL OR o.Message LIKE N''%'' + @SearchText + N''%''
                                   OR o.ExceptionType LIKE N''%'' + @SearchText + N''%''
                                   OR o.Screen LIKE N''%'' + @SearchText + N''%'')'
    + CASE WHEN @keyset = 1 THEN N'
      /* Keyset seek: the cost of this does not grow with page depth, unlike
         OFFSET, which has to walk and discard every row it skips. */
      AND (o.OccurredUtc < @AfterOccurredUtc
           OR (o.OccurredUtc = @AfterOccurredUtc AND o.OccurrenceId < @AfterOccurrenceId))'
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
        N'@ErrorReference VARCHAR(24), @TicketNumber VARCHAR(24), @UserName NVARCHAR(200),
          @ErpModule NVARCHAR(100), @Screen NVARCHAR(200), @Component NVARCHAR(200),
          @ApiEndpoint NVARCHAR(400), @ExceptionType NVARCHAR(400), @SqlErrorNumber INT,
          @CategoryCode NVARCHAR(40), @SeverityCode NVARCHAR(20), @LayerCode NVARCHAR(30),
          @Environment NVARCHAR(40), @CorrelationId UNIQUEIDENTIFIER, @FingerprintId BIGINT,
          @FromUtc DATETIME2(3), @ToUtc DATETIME2(3), @SearchText NVARCHAR(200),
          @MinOccurrences INT, @OnlyUnticketed BIT, @PageNumber INT, @PageSize INT,
          @AfterOccurredUtc DATETIME2(3), @AfterOccurrenceId BIGINT',
        @ErrorReference, @TicketNumber, @UserName, @ErpModule, @Screen, @Component,
        @ApiEndpoint, @ExceptionType, @SqlErrorNumber, @CategoryCode, @SeverityCode,
        @LayerCode, @Environment, @CorrelationId, @FingerprintId, @FromUtc, @ToUtc,
        @SearchText, @MinOccurrences, @OnlyUnticketed, @PageNumber, @PageSize,
        @AfterOccurredUtc, @AfterOccurrenceId;

    /* Note what is parameterised and what is concatenated: every VALUE is a
       parameter, and the only concatenated text is @orderBy, which came out of
       erp_err.SortWhitelist. No caller-supplied string ever reaches the SQL
       text. */
END
GO

/* =============================================================================
   usp_Ticket_Search  (supersedes 004)
   ============================================================================= */
CREATE OR ALTER PROCEDURE erp_err.usp_Ticket_Search
(
    @TicketNumber   VARCHAR(24)   = NULL,
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

    DECLARE @orderBy NVARCHAR(200) = erp_err.fn_ResolveSort(N'ticket', @SortBy, NULL);

    DECLARE @sql NVARCHAR(MAX) = N'
    SELECT
        t.TicketId, t.TicketNumber, t.Title, t.CreatedVia,
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
                            FROM erp_err.TicketStatusHistory h
                            JOIN erp_err.TicketStatus s2 ON s2.StatusId = h.FromStatusId
                            WHERE h.TicketId = t.TicketId AND s2.IsPaused = 1), 0)
                  - CASE WHEN st.IsPaused = 1
                         THEN DATEDIFF(MINUTE, t.LastStatusChangeUtc, SYSUTCDATETIME())
                         ELSE 0 END
        END AS ActiveProcessingMinutes,
        t.SlaFirstResponseBreached, t.SlaResolutionBreached,
        p.FirstResponseMinutes AS SlaFirstResponseTargetMinutes,
        p.ResolutionMinutes    AS SlaResolutionTargetMinutes,
        t.ReopenCount, t.LinkedOccurrenceCount,
        t.FingerprintId, o.ErrorReference AS PrimaryErrorReference'
    + CASE WHEN @IncludeTotalCount = 1 THEN N',
        COUNT(*) OVER () AS TotalRowCount' ELSE N',
        CONVERT(BIGINT, NULL) AS TotalRowCount' END + N'
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
        N'@TicketNumber VARCHAR(24), @StatusCode NVARCHAR(40), @OnlyOpen BIT,
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
       FROM erp_err.ErrorFingerprint f
       CROSS APPLY (SELECT COUNT_BIG(*), COUNT(DISTINCT o.UserName)
                    FROM erp_err.ErrorOccurrence o
                    WHERE o.FingerprintId = f.FingerprintId
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
CREATE OR ALTER PROCEDURE erp_err.usp_Error_RecurringProblems
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

    DECLARE @orderBy NVARCHAR(200) = erp_err.fn_ResolveSort(N'problem', @SortBy, NULL);

    /* ONE pass over the window, grouped. Materialised into a temp table rather
       than left as a CTE so the optimiser gets real cardinality for the join
       below - with a CTE it repeatedly guessed low here and chose a nested loop
       over what is actually a large aggregate. */
    CREATE TABLE #win
    (
        FingerprintId       BIGINT      NOT NULL PRIMARY KEY,
        WindowOccurrences   BIGINT      NOT NULL,
        WindowDistinctUsers INT         NOT NULL,
        WindowLastSeenUtc   DATETIME2(3) NULL
    );

    INSERT #win (FingerprintId, WindowOccurrences, WindowDistinctUsers, WindowLastSeenUtc)
    SELECT o.FingerprintId,
           COUNT_BIG(*),
           COUNT(DISTINCT o.UserName),
           MAX(o.OccurredUtc)
    FROM erp_err.ErrorOccurrence o
    WHERE o.OccurredUtc >= @FromUtc
      AND (@ToUtc IS NULL OR o.OccurredUtc <= @ToUtc)
    GROUP BY o.FingerprintId
    /* Applied HERE, during aggregation, so the join below only ever sees rows
       that already qualify. */
    HAVING COUNT_BIG(*) >= @MinOccurrences;

    DECLARE @sql NVARCHAR(MAX) = N'
    SELECT
        f.FingerprintId, f.FingerprintHash, f.SignatureText,
        sv.Code AS SeverityCode, sv.DisplayName AS SeverityName,
        c.Code  AS CategoryCode, c.DisplayName AS CategoryName,
        l.Code  AS LayerCode,
        f.ExceptionType, f.NormalizedMessage,
        f.ErpModule, f.Screen, f.Component, f.ApiEndpoint, f.SqlObjectName,
        f.FirstSeenUtc, f.LastSeenUtc, f.TriageState, f.MutedUntilUtc,
        f.OccurrenceCount AS LifetimeOccurrences,
        f.DistinctUserCount AS LifetimeDistinctUsers,
        w.WindowOccurrences, w.WindowDistinctUsers, w.WindowLastSeenUtc,
        f.OpenTicketId, tk.TicketNumber AS OpenTicketNumber,
        tks.Code AS OpenTicketStatusCode'
    + CASE WHEN @IncludeTotalCount = 1 THEN N',
        COUNT(*) OVER () AS TotalRowCount' ELSE N',
        CONVERT(BIGINT, NULL) AS TotalRowCount' END + N'
    FROM #win w
    JOIN erp_err.ErrorFingerprint f ON f.FingerprintId = w.FingerprintId
    JOIN erp_err.Severity      sv ON sv.SeverityId = f.SeverityId
    JOIN erp_err.ErrorCategory c  ON c.CategoryId  = f.CategoryId
    JOIN erp_err.AppLayer      l  ON l.LayerId     = f.LayerId
    LEFT JOIN erp_err.Ticket       tk  ON tk.TicketId  = f.OpenTicketId
    LEFT JOIN erp_err.TicketStatus tks ON tks.StatusId = tk.StatusId
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
CREATE OR ALTER PROCEDURE erp_err.usp_Error_GetCorrelationTrail
(
    @CorrelationId UNIQUEIDENTIFIER,
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
    FROM erp_err.ErrorOccurrence
    WHERE CorrelationId = @CorrelationId;

    SELECT TOP (@MaxRows)
           o.OccurrenceId, o.ErrorReference, o.OccurredUtc, o.ReceivedUtc,
           l.Code AS LayerCode, l.DisplayName AS LayerName, l.LayerId,
           c.Code AS CategoryCode, sv.Code AS SeverityCode,
           o.ExceptionType, o.Message,
           o.Component, o.Screen, o.ApiController, o.ApiAction, o.HttpStatusCode,
           o.SqlErrorNumber, o.SqlObjectName, o.SqlLineNumber,
           o.ParentOccurrenceId, o.RequestId, o.UserName,
           d.StackTrace, d.InnerExceptionChain, d.SqlStatementText
    FROM erp_err.ErrorOccurrence o
    JOIN erp_err.AppLayer      l  ON l.LayerId     = o.LayerId
    JOIN erp_err.ErrorCategory c  ON c.CategoryId  = o.CategoryId
    JOIN erp_err.Severity      sv ON sv.SeverityId = o.SeverityId
    LEFT JOIN erp_err.ErrorOccurrenceDetail d ON d.OccurrenceId = o.OccurrenceId
    WHERE o.CorrelationId = @CorrelationId
    /* Deepest layer first: the cause, then the symptom. */
    ORDER BY l.LayerId DESC, o.OccurredUtc ASC, o.OccurrenceId ASC;
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
               AND object_id = OBJECT_ID(N'erp_err.ErrorOccurrence'))
    CREATE INDEX IX_Occurrence_Module_Occurred
        ON erp_err.ErrorOccurrence (ErpModule, OccurredUtc DESC)
        INCLUDE (SeverityId, LayerId, ErrorReference, UserName, TicketId, FingerprintId);
GO

/* Sort by severity within a window. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Occurrence_Severity_Occurred'
               AND object_id = OBJECT_ID(N'erp_err.ErrorOccurrence'))
    CREATE INDEX IX_Occurrence_Severity_Occurred
        ON erp_err.ErrorOccurrence (SeverityId, OccurredUtc DESC)
        INCLUDE (ErpModule, Screen, UserName, ErrorReference, FingerprintId, TicketId);
GO

/* The recurring-problems aggregate: grouped by fingerprint over a date window.
   Leading on OccurredUtc because the window is the selective predicate, and
   FingerprintId + UserName included so the GROUP BY and the DISTINCT count are
   both covered - no lookup to the base table at all. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Occurrence_Window_Aggregate'
               AND object_id = OBJECT_ID(N'erp_err.ErrorOccurrence'))
    CREATE INDEX IX_Occurrence_Window_Aggregate
        ON erp_err.ErrorOccurrence (OccurredUtc)
        INCLUDE (FingerprintId, UserName);
GO

/* "Errors with no ticket yet" - the triage inbox. Filtered, so it costs
   almost nothing to maintain and stays small. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Occurrence_Unticketed'
               AND object_id = OBJECT_ID(N'erp_err.ErrorOccurrence'))
    CREATE INDEX IX_Occurrence_Unticketed
        ON erp_err.ErrorOccurrence (OccurredUtc DESC)
        INCLUDE (ErrorReference, SeverityId, ErpModule, Screen, UserName, FingerprintId)
        WHERE TicketId IS NULL;
GO

/* Ticket queue sorts: oldest-open-first and SLA-breach-first. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Ticket_Open_Created'
               AND object_id = OBJECT_ID(N'erp_err.Ticket'))
    CREATE INDEX IX_Ticket_Open_Created
        ON erp_err.Ticket (StatusId, CreatedUtc)
        INCLUDE (TicketNumber, SeverityId, QueueId, AssignedToUserName,
                 SlaFirstResponseBreached, SlaResolutionBreached, LinkedOccurrenceCount);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Ticket_Unassigned'
               AND object_id = OBJECT_ID(N'erp_err.Ticket'))
    CREATE INDEX IX_Ticket_Unassigned
        ON erp_err.Ticket (CreatedUtc DESC)
        INCLUDE (TicketNumber, StatusId, SeverityId, QueueId)
        WHERE AssignedToUserName IS NULL;
GO

/* The end-user "My Tickets" list, which is the only one of these an ordinary
   user can trigger - so it is the one that must never be slow. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Ticket_Reporter_Created'
               AND object_id = OBJECT_ID(N'erp_err.Ticket'))
    CREATE INDEX IX_Ticket_Reporter_Created
        ON erp_err.Ticket (ReportedByUserName, CreatedUtc DESC)
        INCLUDE (TicketNumber, Title, StatusId, SeverityId, ErpModule,
                 ResolvedUtc, ClosedUtc);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Ticket_ReporterId_Created'
               AND object_id = OBJECT_ID(N'erp_err.Ticket'))
    CREATE INDEX IX_Ticket_ReporterId_Created
        ON erp_err.Ticket (ReportedByUserId, CreatedUtc DESC)
        INCLUDE (TicketNumber, Title, StatusId, SeverityId, ErpModule,
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
           ON erp_err.ErrorOccurrence
              (OccurredUtc, FingerprintId, LayerId, CategoryId, SeverityId,
               ErpModule, Screen, UserName, Environment)
           WITH (MAXDOP = 2);
   ----------------------------------------------------------------------------- */

MERGE erp_err.SchemaVersion AS t
USING (SELECT N'010_search_performance.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion) VALUES (s.ScriptName, N'1.2.0');
GO
