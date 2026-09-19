/* =============================================================================
   ERP Error Management Framework
   Script 012 - Ticket notifications, delivered through the ERP's OWN system

   WHAT ATC ASKED FOR
   ------------------
   "We already have an existing ERP notification system for logged-in users...
    we do not want to introduce Teams or a separate SMTP notification system.
    The ERM framework should integrate with our existing ERP notification
    mechanism where applicable."

   So this script adds no delivery channel at all. It adds the two things that
   are actually missing:

     1. a record of WHAT should be notified, and to WHOM - the outbox;
     2. ONE procedure, ERM.usp_Notification_ErpAdapter, which is the single
        place the ERP's own notification call goes.

   WHY AN OUTBOX AND NOT A DIRECT CALL
   -----------------------------------
   The obvious implementation is to call the notification system from inside
   usp_Ticket_ChangeStatus. Do not. That call would then run INSIDE the ticket
   transaction, which means:

     * if the notification system is slow, changing a ticket's status is slow;
     * if it throws, the status change ROLLS BACK - a notification failure
       would undo the work it was supposed to announce.

   An outbox row is written in the same transaction (so it is exactly as
   durable as the status change, and never announces something that did not
   happen), and delivery is a separate step that can fail, retry and be
   monitored without touching the ticket.

   WHY IT IS NOT DYNAMIC SQL
   -------------------------
   An earlier draft read the target procedure's NAME from a settings row and
   called it with sp_executesql, so it could be pointed anywhere without an
   ALTER. That is a configurable remote-code-execution hole in the one schema
   that holds every stack trace in the system, bought to save one ALTER
   PROCEDURE. There is exactly one ERP here. One adapter procedure, edited
   once, is simpler, safer, and easier to read six months from now.

   Idempotent: yes.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ------------------------------------------------------------- the outbox -- */
IF OBJECT_ID(N'ERM.ERM_NotificationOutbox', N'U') IS NULL
BEGIN
    CREATE TABLE ERM.ERM_NotificationOutbox
    (
        [ROWID]       UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_NotificationOutbox_ROWID DEFAULT (NEWID()),
        [DBNo]        INT              NOT NULL CONSTRAINT DF_NotificationOutbox_DBNo  DEFAULT (1),
        [AppNo]       INT              NOT NULL CONSTRAINT DF_NotificationOutbox_AppNo DEFAULT (1),

        ERM_NotificationOutboxID BIGINT IDENTITY(1,1) NOT NULL,

        /* Who should see it. The ERP UserProfileID - never a name, never an
           address. The ERP's notification system already knows how to reach a
           user; that is precisely why we are using it rather than inventing a
           channel. */
        RecipientUserProfileID INT      NOT NULL,

        /* What happened. 'created' | 'status_changed' | 'assigned' |
           'support_comment' | 'resolved' | 'closed' */
        EventKind       NVARCHAR(30)    NOT NULL,

        ERM_TicketID    BIGINT          NULL,
        TicketNumber    VARCHAR(30)     NULL,

        Title           NVARCHAR(200)   NOT NULL,
        /* Safe, user-facing text. No stack traces, no SQL, no object names -
           the whole point of the framework is that the user never sees those,
           and a notification is still the user seeing something. */
        Body            NVARCHAR(1000)  NOT NULL,
        /* Deep link into the ERP's My Issues panel, if the host wants one. */
        LinkUrl         NVARCHAR(400)   NULL,

        /* pending | sent | failed | skipped */
        DeliveryState   NVARCHAR(20)    NOT NULL CONSTRAINT DF_NotificationOutbox_State DEFAULT (N'pending'),
        AttemptCount    INT             NOT NULL CONSTRAINT DF_NotificationOutbox_Attempts DEFAULT (0),
        LastAttemptUtc  DATETIME2(3)    NULL,
        DeliveredUtc    DATETIME2(3)    NULL,
        LastError       NVARCHAR(2000)  NULL,

        QueuedUtc       DATETIME2(3)    NOT NULL CONSTRAINT DF_NotificationOutbox_Queued DEFAULT (SYSUTCDATETIME()),

        /* ---- standard LinkedScam audit / status columns ---- */
        [IsActive]    BIT      NOT NULL CONSTRAINT DF_NotificationOutbox_IsActive  DEFAULT (1),
        [IsDeleted]   BIT      NOT NULL CONSTRAINT DF_NotificationOutbox_IsDeleted DEFAULT (0),
        [CreatedBy]   INT      NOT NULL,
        [CreatedDate] DATETIME NOT NULL CONSTRAINT DF_NotificationOutbox_CreatedDate DEFAULT (GETUTCDATE()),
        [UpdatedBy]   INT      NULL,
        [UpdatedDate] DATETIME NULL,

        CONSTRAINT PK_NotificationOutbox PRIMARY KEY CLUSTERED (ERM_NotificationOutboxID),
        /* The non-user value cannot receive a notification, because it is not a
           person. Enforced rather than assumed: an auto-rule ticket has -1 as
           its reporter, and without this every one of those would queue an
           undeliverable row for ever. */
        CONSTRAINT CK_NotificationOutbox_RealUser CHECK (RecipientUserProfileID > 0)
    );

    /* The dispatcher's query: pending rows, oldest first. Filtered, so the
       index stays small no matter how much history accumulates. */
    CREATE INDEX IX_NotificationOutbox_Pending
        ON ERM.ERM_NotificationOutbox (QueuedUtc)
        WHERE DeliveryState = N'pending';

    CREATE INDEX IX_NotificationOutbox_Ticket
        ON ERM.ERM_NotificationOutbox (ERM_TicketID, QueuedUtc DESC);
END
GO

/* =============================================================================
   THE ONE PLACE YOU EDIT
   -----------------------------------------------------------------------------
   Replace the body of this procedure with the call into the ERP's existing
   notification system. Nothing else in the framework needs to change, and
   nothing else calls the ERP's notification system.

   It ships as a NO-OP that reports "not wired up yet" rather than as a guess at
   your signature. A stub that pretends to succeed would mean the outbox showed
   every row as delivered while nobody was ever notified - which is the failure
   mode you would discover from a user complaint, months later.

   Typical body once wired up:

       EXEC dbo.usp_LS_Notification_Create
            @UserProfileID = @RecipientUserProfileID,
            @Subject       = @Title,
            @Message       = @Body,
            @Url           = @LinkUrl,
            @CreatedBy     = @RecipientUserProfileID;
       SET @Delivered = 1;

   CONTRACT
     * Set @Delivered = 1 only when the notification is genuinely recorded.
     * Set @FailureReason when it is not; the dispatcher stores it and retries.
     * Do NOT open a transaction here - you are already inside the dispatcher's.
     * Do NOT throw for an expected condition (user has notifications off, say):
       set @Delivered = 0 with a reason, or 1 if "no notification wanted" counts
       as handled. Throwing is reserved for genuine faults.
   ============================================================================= */
CREATE OR ALTER PROCEDURE ERM.usp_Notification_ErpAdapter
(
    @RecipientUserProfileID INT,
    @EventKind      NVARCHAR(30),
    @TicketNumber   VARCHAR(30),
    @Title          NVARCHAR(200),
    @Body           NVARCHAR(1000),
    @LinkUrl        NVARCHAR(400)  = NULL,
    @Delivered      BIT            OUTPUT,
    @FailureReason  NVARCHAR(2000) OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;

    /* ---------------------------------------------------------------------
       REPLACE EVERYTHING BELOW THIS LINE with the call into your own
       notification system.
       --------------------------------------------------------------------- */

    SET @Delivered = 0;
    SET @FailureReason =
        N'ERM.usp_Notification_ErpAdapter has not been wired up to the ERP '
      + N'notification system yet. See db/012_notifications.sql.';
END
GO

/* -----------------------------------------------------------------------------
   Enqueue. Called from inside the ticket procedures, in their transaction.

   Silently does nothing when there is no real recipient. That is the common
   case, not an error: a ticket raised by an automatic rule has -1 as its
   reporter, and there is nobody to tell.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Notification_Enqueue
(
    @RecipientUserProfileID INT,
    @EventKind      NVARCHAR(30),
    @ERM_TicketID   BIGINT,
    @TicketNumber   VARCHAR(30),
    @Title          NVARCHAR(200),
    @Body           NVARCHAR(1000),
    @LinkUrl        NVARCHAR(400) = NULL,
    @ActedByUserProfileID INT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF ERM.fn_SettingBit(N'notify.onStatusChange', 1) = 0 RETURN;

    /* Not a person: nothing to deliver, and the CHECK constraint would reject
       the row anyway. */
    IF @RecipientUserProfileID IS NULL OR @RecipientUserProfileID <= 0 RETURN;

    /* Do not notify somebody about their own action. The user who just typed a
       reply does not need telling that a reply was typed, and support does not
       need telling they assigned the ticket they just assigned. */
    IF @ActedByUserProfileID IS NOT NULL AND @ActedByUserProfileID = @RecipientUserProfileID RETURN;

    INSERT ERM.ERM_NotificationOutbox
        (RecipientUserProfileID, EventKind, ERM_TicketID, TicketNumber,
         Title, Body, LinkUrl, CreatedBy)
    VALUES
        (@RecipientUserProfileID, @EventKind, @ERM_TicketID, @TicketNumber,
         LEFT(@Title, 200), LEFT(@Body, 1000), @LinkUrl,
         ISNULL(@ActedByUserProfileID, ERM.fn_SystemUserID()));
END
GO

/* -----------------------------------------------------------------------------
   Dispatch. Run from SQL Agent, or from the API on a timer - either is fine.

   Each row is delivered in its own transaction, so one bad row cannot roll back
   a batch, and a kill mid-run loses nothing.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Notification_Dispatch
(
    @BatchSize   INT = 200,
    /* Rows that have failed this many times stop being retried. Without this a
       permanently undeliverable row is attempted for ever, and the dispatcher
       spends its life on it instead of on new notifications. */
    @MaxAttempts INT = 5
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @BatchSize IS NULL OR @BatchSize < 1 SET @BatchSize = 200;
    IF @BatchSize > 2000 SET @BatchSize = 2000;

    DECLARE @Pending TABLE
    (
        ERM_NotificationOutboxID BIGINT,
        RecipientUserProfileID INT,
        EventKind      NVARCHAR(30),
        TicketNumber   VARCHAR(30),
        Title          NVARCHAR(200),
        Body           NVARCHAR(1000),
        LinkUrl        NVARCHAR(400)
    );

    INSERT @Pending
    SELECT TOP (@BatchSize)
           ERM_NotificationOutboxID, RecipientUserProfileID, EventKind,
           TicketNumber, Title, Body, LinkUrl
    FROM ERM.ERM_NotificationOutbox
    WHERE DeliveryState = N'pending'
      AND AttemptCount < @MaxAttempts
    ORDER BY QueuedUtc;

    DECLARE @Id BIGINT, @Recipient INT, @Kind NVARCHAR(30), @Ticket VARCHAR(30),
            @Title NVARCHAR(200), @Body NVARCHAR(1000), @Link NVARCHAR(400);
    DECLARE @Delivered BIT, @Reason NVARCHAR(2000);
    DECLARE @Sent INT = 0, @Failed INT = 0;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT ERM_NotificationOutboxID, RecipientUserProfileID, EventKind,
               TicketNumber, Title, Body, LinkUrl
        FROM @Pending;

    OPEN c;
    FETCH NEXT FROM c INTO @Id, @Recipient, @Kind, @Ticket, @Title, @Body, @Link;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Delivered = 0;
        SET @Reason = NULL;

        BEGIN TRY
            EXEC ERM.usp_Notification_ErpAdapter
                 @RecipientUserProfileID = @Recipient,
                 @EventKind      = @Kind,
                 @TicketNumber   = @Ticket,
                 @Title          = @Title,
                 @Body           = @Body,
                 @LinkUrl        = @Link,
                 @Delivered      = @Delivered OUTPUT,
                 @FailureReason  = @Reason    OUTPUT;
        END TRY
        BEGIN CATCH
            SET @Delivered = 0;
            SET @Reason = CONCAT(N'Adapter threw: Msg ', ERROR_NUMBER(),
                                 N', Line ', ERROR_LINE(), N': ', ERROR_MESSAGE());
        END CATCH

        UPDATE ERM.ERM_NotificationOutbox
           SET DeliveryState  = CASE WHEN @Delivered = 1 THEN N'sent'
                                     WHEN AttemptCount + 1 >= @MaxAttempts THEN N'failed'
                                     ELSE N'pending' END,
               AttemptCount   = AttemptCount + 1,
               LastAttemptUtc = SYSUTCDATETIME(),
               DeliveredUtc   = CASE WHEN @Delivered = 1 THEN SYSUTCDATETIME() ELSE DeliveredUtc END,
               LastError      = CASE WHEN @Delivered = 1 THEN NULL ELSE LEFT(@Reason, 2000) END,
               UpdatedBy      = ERM.fn_SystemUserID(),
               UpdatedDate    = GETUTCDATE()
         WHERE ERM_NotificationOutboxID = @Id;

        IF @Delivered = 1 SET @Sent += 1; ELSE SET @Failed += 1;

        FETCH NEXT FROM c INTO @Id, @Recipient, @Kind, @Ticket, @Title, @Body, @Link;
    END

    CLOSE c;
    DEALLOCATE c;

    SELECT @Sent AS Sent, @Failed AS Failed,
           (SELECT COUNT_BIG(*) FROM ERM.ERM_NotificationOutbox
            WHERE DeliveryState = N'pending' AND AttemptCount < @MaxAttempts) AS StillPending;
END
GO

/* -----------------------------------------------------------------------------
   What the console shows about delivery. Chiefly: is anything stuck?
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Notification_Status
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DeliveryState,
           COUNT_BIG(*)       AS RowCountValue,
           MIN(QueuedUtc)     AS OldestQueuedUtc,
           MAX(LastAttemptUtc) AS LastAttemptUtc
    FROM ERM.ERM_NotificationOutbox
    GROUP BY DeliveryState
    ORDER BY DeliveryState;

    /* The one that matters: the adapter is not wired up, so nothing is being
       delivered. Surfaced rather than left to be noticed. */
    SELECT TOP 20 ERM_NotificationOutboxID, TicketNumber, EventKind,
                  RecipientUserProfileID, AttemptCount, LastError, QueuedUtc
    FROM ERM.ERM_NotificationOutbox
    WHERE DeliveryState IN (N'failed', N'pending')
      AND LastError IS NOT NULL
    ORDER BY QueuedUtc DESC;
END
GO

/* Retention: notifications are the most disposable thing in the schema - once
   delivered, the ticket history is the record, not the announcement. */
MERGE ERM.ERM_RetentionPolicy AS t
USING (SELECT N'notification' AS DataSet, 30 AS ArchiveAfterDays,
              90 AS PurgeAfterDays, 5000 AS BatchSize) AS s
    ON t.DataSet = s.DataSet
WHEN NOT MATCHED THEN
    INSERT (DataSet, ArchiveAfterDays, PurgeAfterDays, BatchSize, CreatedBy)
    VALUES (s.DataSet, s.ArchiveAfterDays, s.PurgeAfterDays, s.BatchSize, ERM.fn_SystemUserID());
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'012_notifications.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.4.0', ERM.fn_SystemUserID());
GO
