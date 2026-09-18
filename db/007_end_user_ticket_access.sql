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

   Matching on EITHER UserID OR UserName, because which one is populated depends
   on what the JWT carried at the moment the ticket was raised, and that can
   change across a token format migration.  A ticket raised last year may have
   only a UserName; one raised today may have both.  Requiring UserID would
   silently hide a user's own older tickets from them.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION ERM.fn_UserOwnsTicket
(
    @ERM_TicketID   BIGINT,
    @UserID     NVARCHAR(128),
    @UserName   NVARCHAR(200)
)
RETURNS BIT
AS
BEGIN
    /* No identity supplied = owns nothing.  An anonymous caller must never
       satisfy this, whatever the ticket looks like. */
    IF @UserID IS NULL AND @UserName IS NULL RETURN 0;

    IF EXISTS (
        SELECT 1 FROM ERM.ERM_Ticket t
        WHERE t.ERM_TicketID = @ERM_TicketID
          AND (   (@UserID   IS NOT NULL AND t.ReportedByUserID   = @UserID)
               OR (@UserName IS NOT NULL AND t.ReportedByUserName = @UserName))
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
    @UserID     NVARCHAR(128) = NULL,
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

    /* No identity, no rows.  Deliberately not an error: an unauthenticated
       caller asking for "my tickets" has none, which is a valid answer. */
    IF @UserID IS NULL AND @UserName IS NULL RETURN;

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
    WHERE ((@UserID   IS NOT NULL AND t.ReportedByUserID   = @UserID)
        OR (@UserName IS NOT NULL AND t.ReportedByUserName = @UserName))
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
    @UserID       NVARCHAR(128) = NULL,
    @UserName     NVARCHAR(200) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ERM_TicketID BIGINT =
        (SELECT ERM_TicketID AS TicketId FROM ERM.ERM_Ticket WHERE TicketNumber = @TicketNumber);

    /* Not found and not yours return the same thing: nothing.  The caller
       cannot tell them apart, which is the point. */
    IF @ERM_TicketID IS NULL RETURN;
    IF ERM.fn_UserOwnsTicket(@ERM_TicketID, @UserID, @UserName) = 0 RETURN;

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
    @UserID       NVARCHAR(128) = NULL,
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

    IF @ERM_TicketID IS NULL OR ERM.fn_UserOwnsTicket(@ERM_TicketID, @UserID, @UserName) = 0
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
            (ERM_TicketID, AuthorUserID, AuthorUserName, AuthorRole, CommentText, IsCustomerVisible, CreatedUtc)
        VALUES
            (@ERM_TicketID, @UserID, @UserName, N'reporter', @CommentText, 1, @Now);

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
                     @ChangedByUserID   = @UserID,
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
    INSERT (ScriptName, FrameworkVersion) VALUES (s.ScriptName, N'1.1.0');
GO
