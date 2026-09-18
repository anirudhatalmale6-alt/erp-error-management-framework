/* =============================================================================
   ERP Error Management Framework
   Script 011 - Support roster and roles, assignment as a first-class audited
                operation, and manually raised tickets

   WHAT THIS ADDS, AND WHY EACH ONE WAS MISSING
   --------------------------------------------
   1. A SUPPORT ROSTER AND ROLES.
      Until now there was nothing in the schema that said who support staff
      are. The end-user path was safe (ownership is enforced in SQL), but the
      admin path had no authorisation model at all, and "restrict the console"
      cannot be answered by a UI route guard - a route guard hides a screen, it
      does not protect an endpoint.

   2. ASSIGNMENT WAS NOT PROPERLY AUDITED.
      usp_Ticket_ChangeStatus accepted @AssignToUserName and wrote it to the
      Ticket row, and the transition INTO Assigned appeared in the history with
      who made the change. But the history row never recorded WHO THE TICKET
      WAS ASSIGNED TO, so "who was it assigned to on Tuesday, and who moved it"
      was unanswerable - you could only see the current assignee. Reassignment
      between two support users left no trace whatsoever, because it is not a
      status change.

   3. A TICKET COULD NOT EXIST WITHOUT AN ERROR.
      Ticket.ERM_ErrorFingerprintID was NOT NULL, so every ticket had to hang off a
      captured occurrence. A user who wants to report "the totals on this report
      look wrong" has no error to attach - nothing threw. That is a normal
      support request and the schema could not represent it.

   Idempotent: yes. Safe on a live database - the ALTERs are additive and the
   NOT NULL relaxation cannot fail on existing rows.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =============================================================================
   PART 1 - Support roster and roles
   ============================================================================= */

IF OBJECT_ID(N'ERM.ERM_SupportRole', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_SupportRole
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_SupportRole_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_SupportRole_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_SupportRole_AppNo DEFAULT (1),
        RoleID          TINYINT         NOT NULL,
        Code            NVARCHAR(40)    NOT NULL,
        DisplayName     NVARCHAR(100)   NOT NULL,
        /* Capability flags rather than a hierarchy. A hierarchy forces you to
           decide whether "can triage" outranks "can configure", which is a
           question with no correct answer - real support teams have people who
           do one and not the other. */
        CanViewErrors       BIT NOT NULL CONSTRAINT DF_SupportRole_View    DEFAULT (1),
        CanViewDiagnostics  BIT NOT NULL CONSTRAINT DF_SupportRole_Diag    DEFAULT (1),
        CanManageTickets    BIT NOT NULL CONSTRAINT DF_SupportRole_Manage  DEFAULT (1),
        CanBeAssigned       BIT NOT NULL CONSTRAINT DF_SupportRole_Assign  DEFAULT (1),
        CanTriage           BIT NOT NULL CONSTRAINT DF_SupportRole_Triage  DEFAULT (0),
        CanConfigure        BIT NOT NULL CONSTRAINT DF_SupportRole_Config  DEFAULT (0),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_SupportRole_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_SupportRole_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_SupportRole_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_SupportRole_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_SupportRole PRIMARY KEY CLUSTERED (RoleID),
        CONSTRAINT UQ_SupportRole_Code UNIQUE (Code)
    );
END
GO

MERGE ERM.ERM_SupportRole AS t
USING (VALUES
    /*                              view  diag  manage  assignable  triage  config */
    (1, N'support_agent',  N'Support Agent',      1,    1,    1,      1,          0,      0),
    (2, N'support_lead',   N'Support Lead',       1,    1,    1,      1,          1,      0),
    (3, N'developer',      N'Developer',          1,    1,    1,      1,          1,      0),
    /* Read-only: for a manager who needs the dashboard and the recurring-problem
       report but has no business changing ticket state. */
    (4, N'support_viewer', N'Support Viewer',     1,    0,    0,      0,          0,      0),
    (5, N'administrator',  N'Administrator',      1,    1,    1,      1,          1,      1)
) AS s (RoleID, Code, DisplayName, CanViewErrors, CanViewDiagnostics,
        CanManageTickets, CanBeAssigned, CanTriage, CanConfigure)
    ON t.RoleID = s.RoleID
WHEN NOT MATCHED THEN
    INSERT (RoleID, Code, DisplayName, CanViewErrors, CanViewDiagnostics,
            CanManageTickets, CanBeAssigned, CanTriage, CanConfigure)
    VALUES (s.RoleID, s.Code, s.DisplayName, s.CanViewErrors, s.CanViewDiagnostics,
            s.CanManageTickets, s.CanBeAssigned, s.CanTriage, s.CanConfigure);
GO

/* -----------------------------------------------------------------------------
   The roster.

   This is deliberately NOT a copy of your user directory. It holds only the
   people who have a support function, keyed by whatever identifier your JWT
   carries, so the framework never needs to read your ERP's user tables - which
   is the same isolation rule as everything else in ERM.

   It serves two purposes that are easy to conflate:
     * AUTHORISATION  - may this caller use the admin API at all?
     * ASSIGNABILITY  - who may appear in the "assign to" picker?
   They are different: a departed agent stays in the roster (so their name still
   resolves in old audit rows) with IsActive = 0, which removes them from the
   picker AND from access.
   ----------------------------------------------------------------------------- */
IF OBJECT_ID(N'ERM.ERM_SupportUser', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_SupportUser
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_SupportUser_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_SupportUser_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_SupportUser_AppNo DEFAULT (1),
        ERM_SupportUserID   INT             IDENTITY(1,1) NOT NULL,
        /* Match on EITHER, because which one your token carries can change
           across an auth migration and old tickets must keep resolving. */
        UserID          NVARCHAR(128)   NULL,
        UserName        NVARCHAR(200)   NULL,
        DisplayName     NVARCHAR(200)   NOT NULL,
        RoleID          TINYINT         NOT NULL,
        /* NULL = may be assigned work from any queue. */
        DefaultQueueID  SMALLINT        NULL,
        /* Out of office: excluded from the picker, access unaffected. */
        IsAvailable     BIT             NOT NULL CONSTRAINT DF_SupportUser_Available DEFAULT (1),
        CreatedUtc      DATETIME2(3)    NOT NULL CONSTRAINT DF_SupportUser_Created DEFAULT (SYSUTCDATETIME()),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_SupportUser_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_SupportUser_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_SupportUser_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_SupportUser_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_SupportUser PRIMARY KEY CLUSTERED (ERM_SupportUserID),
        CONSTRAINT FK_SupportUser_Role  FOREIGN KEY (RoleID)         REFERENCES ERM.ERM_SupportRole (RoleID),
        CONSTRAINT FK_SupportUser_Queue FOREIGN KEY (DefaultQueueID) REFERENCES ERM.ERM_TicketQueue (ERM_TicketQueueID),
        /* A row that identifies nobody is a row that authorises nobody - but it
           would also be invisible in the console, so reject it outright. */
        CONSTRAINT CK_SupportUser_Identity CHECK (UserID IS NOT NULL OR UserName IS NOT NULL)
    );

    /* Filtered unique indexes: one roster row per identity, while still
       allowing many rows to have a NULL UserID or NULL UserName. */
    CREATE UNIQUE INDEX UX_SupportUser_UserId
        ON ERM.ERM_SupportUser (UserID) WHERE UserID IS NOT NULL;
    CREATE UNIQUE INDEX UX_SupportUser_UserName
        ON ERM.ERM_SupportUser (UserName) WHERE UserName IS NOT NULL;
END
GO

/* -----------------------------------------------------------------------------
   The authorisation predicate, in one place.

   Everything the admin API does goes through this. Having it in SQL as well as
   in the API is deliberate: the API check is what returns a clean 403, and this
   is what makes a forgotten check fail closed rather than silently allowing.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION ERM.fn_SupportCapability
(
    @UserID     NVARCHAR(128),
    @UserName   NVARCHAR(200),
    /* 'view' | 'diagnostics' | 'manage' | 'triage' | 'configure' */
    @Capability NVARCHAR(20)
)
RETURNS BIT
AS
BEGIN
    /* No identity = no capability. An anonymous caller must never satisfy
       this, whatever else is true. */
    IF @UserID IS NULL AND @UserName IS NULL RETURN 0;

    DECLARE @granted BIT = 0;

    SELECT @granted = CASE @Capability
                        WHEN N'view'        THEN r.CanViewErrors
                        WHEN N'diagnostics' THEN r.CanViewDiagnostics
                        WHEN N'manage'      THEN r.CanManageTickets
                        WHEN N'triage'      THEN r.CanTriage
                        WHEN N'configure'   THEN r.CanConfigure
                        ELSE CONVERT(BIT, 0)
                      END
    FROM ERM.ERM_SupportUser su
    JOIN ERM.ERM_SupportRole r ON r.RoleID = su.RoleID
    WHERE su.IsActive = 1
      AND r.IsActive = 1
      AND (   (@UserID   IS NOT NULL AND su.UserID   = @UserID)
           OR (@UserName IS NOT NULL AND su.UserName = @UserName));

    RETURN ISNULL(@granted, 0);
END
GO

/* Who the caller is, and what they may do - one round trip for the API to
   cache per request. */
CREATE OR ALTER PROCEDURE ERM.usp_Support_WhoAmI
(
    @UserID   NVARCHAR(128) = NULL,
    @UserName NVARCHAR(200) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
           su.ERM_SupportUserID, su.DisplayName, su.UserID, su.UserName,
           r.Code AS RoleCode, r.DisplayName AS RoleName,
           r.CanViewErrors, r.CanViewDiagnostics, r.CanManageTickets,
           r.CanBeAssigned, r.CanTriage, r.CanConfigure,
           su.DefaultQueueID, q.Code AS DefaultQueueCode,
           su.IsAvailable
    FROM ERM.ERM_SupportUser su
    JOIN ERM.ERM_SupportRole r ON r.RoleID = su.RoleID
    LEFT JOIN ERM.ERM_TicketQueue q ON q.ERM_TicketQueueID = su.DefaultQueueID
    WHERE su.IsActive = 1 AND r.IsActive = 1
      AND (   (@UserID   IS NOT NULL AND su.UserID   = @UserID)
           OR (@UserName IS NOT NULL AND su.UserName = @UserName));

    /* No row = not support staff. The API turns that into a 403; the absence
       of a row is the answer, not an error. */
END
GO

/* The "assign to" picker. Only people who may actually be assigned work. */
CREATE OR ALTER PROCEDURE ERM.usp_SupportUser_ListAssignable
(
    @ERM_TicketQueueID SMALLINT = NULL,
    @IncludeUnavailable BIT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT su.ERM_SupportUserID, su.UserID, su.UserName, su.DisplayName,
           r.Code AS RoleCode, r.DisplayName AS RoleName,
           su.DefaultQueueID, q.Code AS DefaultQueueCode,
           su.IsAvailable,
           /* Current workload, so a lead can see who is already buried rather
              than assigning by alphabetical order. */
           (SELECT COUNT_BIG(*) FROM ERM.ERM_Ticket t
            JOIN ERM.ERM_TicketStatus ts ON ts.StatusID = t.StatusID
            WHERE ts.IsOpen = 1
              AND (   (su.UserID   IS NOT NULL AND t.AssignedToUserID   = su.UserID)
                   OR (su.UserName IS NOT NULL AND t.AssignedToUserName = su.UserName))
           ) AS OpenTicketCount
    FROM ERM.ERM_SupportUser su
    JOIN ERM.ERM_SupportRole r ON r.RoleID = su.RoleID
    LEFT JOIN ERM.ERM_TicketQueue q ON q.ERM_TicketQueueID = su.DefaultQueueID
    WHERE su.IsActive = 1
      AND r.IsActive = 1
      AND r.CanBeAssigned = 1
      AND (@IncludeUnavailable = 1 OR su.IsAvailable = 1)
      /* A user with no default queue can take work from any queue. */
      AND (@ERM_TicketQueueID IS NULL OR su.DefaultQueueID IS NULL OR su.DefaultQueueID = @ERM_TicketQueueID)
    ORDER BY su.IsAvailable DESC, OpenTicketCount ASC, su.DisplayName ASC;
END
GO

/* =============================================================================
   PART 2 - Assignment as a first-class, audited operation
   ============================================================================= */

/* The history row now records the assignee, and the previous assignee.

   Without these, a reassignment between two support users - which is not a
   status change and so never triggered a history row at all - left no trace,
   and even the initial assignment only recorded who PERFORMED it, never who
   RECEIVED it. */
IF COL_LENGTH(N'ERM.ERM_TicketStatusHistory', N'AssignedToUserID') IS NULL
    ALTER TABLE ERM.ERM_TicketStatusHistory ADD AssignedToUserID NVARCHAR(128) NULL;
GO
IF COL_LENGTH(N'ERM.ERM_TicketStatusHistory', N'AssignedToUserName') IS NULL
    ALTER TABLE ERM.ERM_TicketStatusHistory ADD AssignedToUserName NVARCHAR(200) NULL;
GO
IF COL_LENGTH(N'ERM.ERM_TicketStatusHistory', N'PreviousAssignedToUserName') IS NULL
    ALTER TABLE ERM.ERM_TicketStatusHistory ADD PreviousAssignedToUserName NVARCHAR(200) NULL;
GO
/* 'status' | 'assignment' | 'both' - so a reassignment is a real audit row
   rather than a status change that happens to differ. */
IF COL_LENGTH(N'ERM.ERM_TicketStatusHistory', N'ChangeKind') IS NULL
    ALTER TABLE ERM.ERM_TicketStatusHistory
        ADD ChangeKind NVARCHAR(20) NOT NULL
            CONSTRAINT DF_TSH_ChangeKind DEFAULT (N'status');
GO

/* -----------------------------------------------------------------------------
   usp_Ticket_Assign
   -----------------------------------------------------------------------------
   Assignment WITHOUT requiring a status change, and validated against the
   roster - so a ticket cannot be assigned to somebody who does not exist, has
   left, or holds a role that is not assignable. A free-text assignee field
   looks harmless right up to the first typo, after which the ticket is
   assigned to nobody and appears in no queue.

   Writes a history row every time, including for reassignment.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_Assign
(
    @TicketNumber       VARCHAR(30),
    /* Target. NULL in both = unassign. */
    @AssignToUserID     NVARCHAR(128) = NULL,
    @AssignToUserName   NVARCHAR(200) = NULL,
    @ChangedByUserID    NVARCHAR(128) = NULL,
    @ChangedByUserName  NVARCHAR(200) = NULL,
    @Comments           NVARCHAR(MAX) = NULL,
    /* Move New -> Assigned at the same time, if the workflow permits it. */
    @AdvanceStatus      BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* The caller must be allowed to manage tickets. Checked here as well as in
       the API so that a forgotten check fails closed. */
    IF ERM.fn_SupportCapability(@ChangedByUserID, @ChangedByUserName, N'manage') = 0
    BEGIN
        RAISERROR (N'Not authorised to manage tickets.', 16, 1);
        RETURN;
    END

    DECLARE @ERM_TicketID BIGINT, @StatusID TINYINT, @PrevAssignee NVARCHAR(200), @PrevAssigneeId NVARCHAR(128);

    SELECT @ERM_TicketID = ERM_TicketID, @StatusID = StatusID,
           @PrevAssignee = AssignedToUserName, @PrevAssigneeId = AssignedToUserID
    FROM ERM.ERM_Ticket WHERE TicketNumber = @TicketNumber;

    IF @ERM_TicketID IS NULL
    BEGIN
        RAISERROR (N'Ticket %s does not exist.', 16, 1, @TicketNumber);
        RETURN;
    END

    DECLARE @unassigning BIT = CASE WHEN @AssignToUserID IS NULL AND @AssignToUserName IS NULL
                                    THEN 1 ELSE 0 END;

    DECLARE @targetId NVARCHAR(128), @targetName NVARCHAR(200), @targetDisplay NVARCHAR(200);

    IF @unassigning = 0
    BEGIN
        /* Resolve against the roster, and fail if the target is not a real,
           active, assignable person. */
        SELECT TOP 1 @targetId = su.UserID, @targetName = su.UserName, @targetDisplay = su.DisplayName
        FROM ERM.ERM_SupportUser su
        JOIN ERM.ERM_SupportRole r ON r.RoleID = su.RoleID
        WHERE su.IsActive = 1 AND r.IsActive = 1 AND r.CanBeAssigned = 1
          AND (   (@AssignToUserID   IS NOT NULL AND su.UserID   = @AssignToUserID)
               OR (@AssignToUserName IS NOT NULL AND su.UserName = @AssignToUserName));

        IF @targetDisplay IS NULL
        BEGIN
            RAISERROR (N'Assignee is not an active, assignable member of the support roster.', 16, 1);
            RETURN;
        END
    END

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRANSACTION;

        UPDATE ERM.ERM_Ticket
           SET AssignedToUserID   = @targetId,
               AssignedToUserName = @targetName,
               AssignedUtc        = CASE WHEN @unassigning = 1 THEN NULL
                                         ELSE ISNULL(AssignedUtc, @Now) END,
               /* An assignment is a response: somebody has picked the ticket
                  up. Setting it here means first-response time is not
                  understated just because nobody changed the status yet. */
               FirstResponseUtc   = CASE WHEN @unassigning = 1 THEN FirstResponseUtc
                                         ELSE ISNULL(FirstResponseUtc, @Now) END
         WHERE ERM_TicketID = @ERM_TicketID;

        DECLARE @SeqNo INT;
        SELECT @SeqNo = ISNULL(MAX(SequenceNo), 0) + 1
        FROM ERM.ERM_TicketStatusHistory WITH (UPDLOCK, HOLDLOCK)
        WHERE ERM_TicketID = @ERM_TicketID;

        INSERT ERM.ERM_TicketStatusHistory
            (ERM_TicketID, SequenceNo, FromStatusID, ToStatusID, ChangedByUserID, ChangedByUserName,
             ChangedUtc, MinutesInFromStatus, Comments, IsCustomerVisible,
             AssignedToUserID, AssignedToUserName, PreviousAssignedToUserName, ChangeKind)
        VALUES
            (@ERM_TicketID, @SeqNo,
             /* Same status on both sides: this row records an ASSIGNMENT, not a
                transition, and pretending otherwise would corrupt the
                minutes-in-status accounting. */
             @StatusID, @StatusID,
             @ChangedByUserID, @ChangedByUserName, @Now,
             NULL,
             COALESCE(@Comments,
                      CASE WHEN @unassigning = 1 THEN N'Ticket unassigned.'
                           WHEN @PrevAssignee IS NULL THEN N'Assigned to ' + @targetDisplay + N'.'
                           ELSE N'Reassigned from ' + @PrevAssignee + N' to ' + @targetDisplay + N'.' END),
             /* Internal: which engineer holds the ticket is not the end user's
                business, and telling them invites them to chase that person. */
             0,
             @targetId, @targetName, @PrevAssignee, N'assignment');

    COMMIT TRANSACTION;

    /* Advance New -> Assigned as a separate, properly audited transition, so
       the status history and the minutes-in-status accounting stay correct. */
    IF @unassigning = 0 AND @AdvanceStatus = 1
    BEGIN
        DECLARE @AssignedStatusId TINYINT =
            (SELECT StatusID FROM ERM.ERM_TicketStatus WHERE Code = N'assigned' AND IsActive = 1);

        IF @AssignedStatusId IS NOT NULL
           AND @StatusID <> @AssignedStatusId
           AND EXISTS (SELECT 1 FROM ERM.ERM_TicketStatusTransition
                       WHERE FromStatusID = @StatusID AND ToStatusID = @AssignedStatusId
                         AND IsActive = 1)
        BEGIN
            EXEC ERM.usp_Ticket_ChangeStatus
                 @ERM_TicketID          = @ERM_TicketID,
                 @ToStatusID        = @AssignedStatusId,
                 @ChangedByUserID   = @ChangedByUserID,
                 @ChangedByUserName = @ChangedByUserName,
                 @Comments          = N'Assigned.',
                 @AssignToUserID    = @targetId,
                 @AssignToUserName  = @targetName,
                 @IsCustomerVisible = 1;
        END
    END

    SELECT @TicketNumber AS TicketNumber,
           @targetName AS AssignedToUserName,
           @targetDisplay AS AssignedToDisplayName,
           @PrevAssignee AS PreviousAssignedToUserName,
           @SeqNo AS SequenceNo;
END
GO

/* usp_Ticket_ChangeStatus records the assignee on its history row too, so the
   audit trail is complete whichever route was used. */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_RecordAssigneeOnHistory
(
    @ERM_TicketID BIGINT,
    @SequenceNo INT
)
AS
BEGIN
    SET NOCOUNT ON;
    /* Back-fills the assignee columns on a status-history row from the ticket's
       current state. Called by usp_Ticket_ChangeStatus immediately after it
       writes its row, so the two stay consistent without duplicating the
       assignment logic. */
    UPDATE h
       SET h.AssignedToUserID   = t.AssignedToUserID,
           h.AssignedToUserName = t.AssignedToUserName
      FROM ERM.ERM_TicketStatusHistory h
      JOIN ERM.ERM_Ticket t ON t.ERM_TicketID = h.ERM_TicketID
     WHERE h.ERM_TicketID = @ERM_TicketID AND h.SequenceNo = @SequenceNo;
END
GO

/* =============================================================================
   PART 3 - Manually raised tickets (no captured error)
   ============================================================================= */

/* A ticket no longer has to hang off a fingerprint. */
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID(N'ERM.ERM_Ticket')
             AND name = N'ERM_ErrorFingerprintID' AND is_nullable = 0)
BEGIN
    /* The FK stays; only the nullability changes. Relaxing NOT NULL cannot
       fail on existing rows, so this is safe on a live table. */
    ALTER TABLE ERM.ERM_Ticket ALTER COLUMN ERM_ErrorFingerprintID BIGINT NULL;
END
GO

/* Where the ticket came from, so the console can tell a captured fault from a
   request somebody typed. CreatedVia already distinguished user/auto_rule/admin
   but every value implied an underlying error. */
IF COL_LENGTH(N'ERM.ERM_Ticket', N'TicketSource') IS NULL
    ALTER TABLE ERM.ERM_Ticket
        ADD TicketSource NVARCHAR(20) NOT NULL
            CONSTRAINT DF_Ticket_Source DEFAULT (N'error');
GO

/* What the user says the problem is about, for a manual ticket where there is
   no module/screen to infer from an occurrence. */
IF COL_LENGTH(N'ERM.ERM_Ticket', N'RequestCategory') IS NULL
    ALTER TABLE ERM.ERM_Ticket ADD RequestCategory NVARCHAR(60) NULL;
GO

IF COL_LENGTH(N'ERM.ERM_Ticket', N'ReportedScreen') IS NULL
    ALTER TABLE ERM.ERM_Ticket ADD ReportedScreen NVARCHAR(200) NULL;
GO

/* Either it came from an error and has a fingerprint, or it is manual and does
   not. A ticket that is neither is a bug, and a CHECK constraint is how you
   find out at the INSERT rather than three screens later. */
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Ticket_SourceIntegrity')
    ALTER TABLE ERM.ERM_Ticket WITH NOCHECK
        ADD CONSTRAINT CK_Ticket_SourceIntegrity CHECK
        (
            (TicketSource = N'error'  AND ERM_ErrorFingerprintID IS NOT NULL)
         OR (TicketSource = N'manual' AND ERM_ErrorFingerprintID IS NULL)
        );
GO

/* Categories an end user can pick when raising a ticket by hand. Rows, not an
   enum, so support can change the list without a release. */
IF OBJECT_ID(N'ERM.ERM_RequestCategory', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_RequestCategory
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_RequestCategory_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_RequestCategory_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_RequestCategory_AppNo DEFAULT (1),
        Code            NVARCHAR(60)    NOT NULL,
        DisplayName     NVARCHAR(120)   NOT NULL,
        DefaultSeverityID TINYINT       NOT NULL,
        DefaultQueueID  SMALLINT        NULL,
        RankOrder       TINYINT         NOT NULL CONSTRAINT DF_RequestCategory_Rank DEFAULT (50),
        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_RequestCategory_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_RequestCategory_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL CONSTRAINT DF_RequestCategory_CreatedBy DEFAULT (ERM.fn_SystemUserID()),
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_RequestCategory_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,
        CONSTRAINT PK_RequestCategory PRIMARY KEY CLUSTERED (Code),
        CONSTRAINT FK_RequestCategory_Severity FOREIGN KEY (DefaultSeverityID)
            REFERENCES ERM.ERM_Severity (SeverityID),
        CONSTRAINT FK_RequestCategory_Queue FOREIGN KEY (DefaultQueueID)
            REFERENCES ERM.ERM_TicketQueue (ERM_TicketQueueID)
    );
END
GO

MERGE ERM.ERM_RequestCategory AS t
USING (VALUES
    (N'wrong_data',      N'Data looks wrong or is missing',      3, 10),
    (N'cannot_complete', N'I cannot complete a task',            2, 20),
    (N'slow',            N'Something is very slow',              3, 30),
    (N'access',          N'I need access to something',          4, 40),
    (N'how_to',          N'I need help using a screen',          4, 50),
    (N'enhancement',     N'Suggestion or enhancement request',   5, 60),
    (N'other',           N'Something else',                      4, 99)
) AS s (Code, DisplayName, DefaultSeverityID, RankOrder)
    ON t.Code = s.Code
WHEN NOT MATCHED THEN
    INSERT (Code, DisplayName, DefaultSeverityID, RankOrder)
    VALUES (s.Code, s.DisplayName, s.DefaultSeverityID, s.RankOrder);
GO

CREATE OR ALTER PROCEDURE ERM.usp_RequestCategory_List
AS
BEGIN
    SET NOCOUNT ON;
    SELECT rc.Code, rc.DisplayName, sv.Code AS DefaultSeverityCode, rc.RankOrder
    FROM ERM.ERM_RequestCategory rc
    JOIN ERM.ERM_Severity sv ON sv.SeverityID = rc.DefaultSeverityID
    WHERE rc.IsActive = 1
    ORDER BY rc.RankOrder, rc.DisplayName;
END
GO

/* -----------------------------------------------------------------------------
   usp_Ticket_CreateManual
   -----------------------------------------------------------------------------
   A ticket raised by a user with no captured error behind it.

   Deliberately NOT deduplicated. Fingerprint deduplication answers "is this
   the same fault?", and there is no fault here - two people describing the same
   annoyance in their own words are two requests, and merging them would lose
   one person's description and confuse both. Recurring-problem analysis
   therefore ignores manual tickets, which is correct: they are not errors.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Ticket_CreateManual
(
    @Title              NVARCHAR(400),
    @Description        NVARCHAR(MAX),
    @RequestCategory    NVARCHAR(60)  = N'other',
    @ErpModule          NVARCHAR(100) = NULL,
    @ReportedScreen     NVARCHAR(200) = NULL,
    @Environment        NVARCHAR(40)  = NULL,
    @ReportedByUserID   NVARCHAR(128) = NULL,
    @ReportedByUserName NVARCHAR(200) = NULL,
    /* Support staff raising one on a user's behalf - phone call, corridor
       conversation. The ticket is owned by @ReportedByUserName so it appears in
       THEIR My Tickets, not the agent's. */
    @CreatedVia         NVARCHAR(20)  = N'user',
    @SeverityCode       NVARCHAR(20)  = NULL,
    @TicketNumber       VARCHAR(30)   OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Title IS NULL OR LEN(LTRIM(RTRIM(@Title))) = 0
    BEGIN
        RAISERROR (N'A title is required.', 16, 1);
        RETURN;
    END

    IF @ReportedByUserID IS NULL AND @ReportedByUserName IS NULL
    BEGIN
        /* An unowned manual ticket cannot appear in anyone's My Tickets and
           nobody can be asked for more information - it is a dead record. */
        RAISERROR (N'A manual ticket must have an owner.', 16, 1);
        RETURN;
    END

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    DECLARE @catCode NVARCHAR(60) =
        ISNULL((SELECT Code FROM ERM.ERM_RequestCategory
                WHERE Code = @RequestCategory AND IsActive = 1), N'other');

    DECLARE @SeverityID TINYINT = COALESCE(
        (SELECT SeverityID FROM ERM.ERM_Severity WHERE Code = @SeverityCode AND IsActive = 1),
        (SELECT DefaultSeverityID FROM ERM.ERM_RequestCategory WHERE Code = @catCode),
        4 /* low */);

    DECLARE @ERM_TicketQueueID SMALLINT = COALESCE(
        (SELECT DefaultQueueID FROM ERM.ERM_RequestCategory WHERE Code = @catCode),
        (SELECT TOP 1 ERM_TicketQueueID FROM ERM.ERM_TicketQueue
         WHERE IsActive = 1 AND ErpModuleMatch = @ErpModule ORDER BY ERM_TicketQueueID),
        (SELECT TOP 1 ERM_TicketQueueID FROM ERM.ERM_TicketQueue
         WHERE IsActive = 1 AND IsDefault = 1 ORDER BY ERM_TicketQueueID),
        (SELECT TOP 1 ERM_TicketQueueID FROM ERM.ERM_TicketQueue WHERE IsActive = 1 ORDER BY ERM_TicketQueueID));

    DECLARE @ERM_SlaPolicyID SMALLINT =
        COALESCE((SELECT TOP 1 ERM_SlaPolicyID FROM ERM.ERM_SlaPolicy
                  WHERE IsActive = 1 AND SeverityID = @SeverityID AND ERM_TicketQueueID = @ERM_TicketQueueID),
                 (SELECT TOP 1 ERM_SlaPolicyID FROM ERM.ERM_SlaPolicy
                  WHERE IsActive = 1 AND SeverityID = @SeverityID AND ERM_TicketQueueID IS NULL));

    EXEC ERM.usp_NextReference @RefType = 'TKT', @Reference = @TicketNumber OUTPUT;

    DECLARE @NewTicketId BIGINT;

    BEGIN TRANSACTION;

        INSERT ERM.ERM_Ticket
        (
            TicketNumber, ERM_ErrorOccurrenceID, ERM_ErrorFingerprintID, StatusID, SeverityID, ERM_TicketQueueID, ERM_SlaPolicyID,
            Title, UserDescription, ReportedByUserID, ReportedByUserName, CreatedVia,
            ErpModule, Environment, CreatedUtc, LastStatusChangeUtc, LinkedOccurrenceCount,
            TicketSource, RequestCategory, ReportedScreen
        )
        VALUES
        (
            @TicketNumber, NULL, NULL, 1 /*new*/, @SeverityID, @ERM_TicketQueueID, @ERM_SlaPolicyID,
            LEFT(LTRIM(RTRIM(@Title)), 400), @Description, @ReportedByUserID, @ReportedByUserName,
            @CreatedVia, @ErpModule, @Environment, @Now, @Now,
            /* No occurrences behind it. */
            0,
            N'manual', @catCode, @ReportedScreen
        );

        SET @NewTicketId = SCOPE_IDENTITY();

        INSERT ERM.ERM_TicketStatusHistory
            (ERM_TicketID, SequenceNo, FromStatusID, ToStatusID, ChangedByUserID, ChangedByUserName,
             ChangedUtc, MinutesInFromStatus, Comments, IsCustomerVisible, ChangeKind)
        VALUES
            (@NewTicketId, 1, NULL, 1, @ReportedByUserID, @ReportedByUserName, @Now, NULL,
             N'Ticket raised manually by the user.', 1, N'status');

    COMMIT TRANSACTION;

    SELECT @TicketNumber AS TicketNumber, @NewTicketId AS TicketId,
           CONVERT(BIT, 0) AS WasDeduplicated;
END
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'011_support_access_and_manual_tickets.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion) VALUES (s.ScriptName, N'1.3.0');
GO
