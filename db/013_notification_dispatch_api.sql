/* =============================================================================
   ERP Error Management Framework
   Script 013 - Claim/complete API for an EXTERNAL notification dispatcher

   WHY THIS EXISTS
   ---------------
   012 delivers notifications by calling ERM.usp_Notification_ErpAdapter, which
   is the right shape when the ERP's notification system is reachable from
   inside SQL Server - you write one EXEC and you are done.

   Email is not that shape. Sending mail from SQL Server means Database Mail,
   which needs sysadmin to configure, a service broker queue, msdb objects, and
   an outbound connection from the database engine itself. That is a large
   amount of standing configuration on a production instance, added for one
   feature, and it puts an SMTP timeout inside the database.

   So mail is sent by the APPLICATION, which already has a mail client, already
   has credentials in its configuration, and can be restarted without touching
   the database. This script gives that application the two calls it needs:

       usp_Notification_Claim        take the next N pending rows
       usp_Notification_MarkResult   report what happened to one row

   Nothing here sends anything. There is deliberately no SMTP host, no port and
   no password in the database.

   WHY "CLAIM" AND NOT "SELECT"
   ----------------------------
   The obvious version reads pending rows with a SELECT, sends them, then
   updates. Run two application instances - or one instance during a rolling
   restart - and both read the same rows and both send. The user gets every
   notification twice, and nothing in the logs suggests why.

   So claiming is a single atomic UPDATE that marks the rows and returns them in
   the same statement, exactly as the reference-number generator does:

       UPDATE TOP (@n) ... SET DeliveryState = 'sending'
       OUTPUT inserted.* ...

   A row can therefore be claimed by exactly one caller. The cost is that a
   dispatcher which dies mid-flight leaves rows stuck in 'sending', which
   usp_Notification_ReleaseStale puts back - visible and bounded, rather than a
   silent double-send.

   Idempotent: yes.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* 'sending' joins pending | sent | failed | skipped. Added rather than assumed,
   because 012 shipped without it. */
IF COL_LENGTH(N'ERM.ERM_NotificationOutbox', N'ClaimedUtc') IS NULL
    ALTER TABLE ERM.ERM_NotificationOutbox ADD ClaimedUtc DATETIME2(3) NULL;
GO

/* Who claimed it. Not for the application's benefit - for yours, at 2am, when
   you want to know which node stopped sending. */
IF COL_LENGTH(N'ERM.ERM_NotificationOutbox', N'ClaimedBy') IS NULL
    ALTER TABLE ERM.ERM_NotificationOutbox ADD ClaimedBy NVARCHAR(128) NULL;
GO

/* -----------------------------------------------------------------------------
   usp_Notification_Claim
   -----------------------------------------------------------------------------
   Takes up to @BatchSize pending rows, marks them 'sending', and returns them.
   The caller must report each one back through usp_Notification_MarkResult.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Notification_Claim
(
    @BatchSize   INT = 50,
    @MaxAttempts INT = 5,
    /* Free text identifying this dispatcher - machine name is ideal. */
    @ClaimedBy   NVARCHAR(128) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @BatchSize IS NULL OR @BatchSize < 1 SET @BatchSize = 50;
    IF @BatchSize > 500 SET @BatchSize = 500;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    /* Single statement: mark and return together, so two dispatchers cannot
       both take the same row. READPAST skips rows another session is already
       claiming rather than queueing behind them - a slow claim elsewhere should
       not stall this one. */
    UPDATE TOP (@BatchSize) o
       SET o.DeliveryState = N'sending',
           o.ClaimedUtc    = @Now,
           o.ClaimedBy     = @ClaimedBy,
           o.UpdatedBy     = ERM.fn_SystemUserID(),
           o.UpdatedDate   = GETUTCDATE()
    OUTPUT inserted.ERM_NotificationOutboxID,
           inserted.RecipientUserProfileID,
           inserted.EventKind,
           inserted.TicketNumber,
           inserted.Title,
           inserted.Body,
           inserted.LinkUrl,
           inserted.AttemptCount
      FROM ERM.ERM_NotificationOutbox o WITH (READPAST)
     WHERE o.DeliveryState = N'pending'
       AND o.AttemptCount  < @MaxAttempts;
END
GO

/* -----------------------------------------------------------------------------
   usp_Notification_MarkResult
   -----------------------------------------------------------------------------
   Report the outcome of one claimed row.

   A failure that has used up its attempts becomes 'failed' and is not retried.
   Anything else goes back to 'pending' for the next run.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Notification_MarkResult
(
    @ERM_NotificationOutboxID BIGINT,
    @Delivered     BIT,
    @FailureReason NVARCHAR(2000) = NULL,
    @MaxAttempts   INT = 5
)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE ERM.ERM_NotificationOutbox
       SET AttemptCount   = AttemptCount + 1,
           LastAttemptUtc = SYSUTCDATETIME(),
           DeliveryState  = CASE
                                WHEN @Delivered = 1 THEN N'sent'
                                WHEN AttemptCount + 1 >= @MaxAttempts THEN N'failed'
                                ELSE N'pending'
                            END,
           DeliveredUtc   = CASE WHEN @Delivered = 1 THEN SYSUTCDATETIME() ELSE DeliveredUtc END,
           /* Cleared on success. A stale error message next to a delivered row
              is how somebody spends an afternoon chasing a problem that was
              fixed two attempts ago. */
           LastError      = CASE WHEN @Delivered = 1 THEN NULL ELSE LEFT(@FailureReason, 2000) END,
           ClaimedUtc     = NULL,
           ClaimedBy      = NULL,
           UpdatedBy      = ERM.fn_SystemUserID(),
           UpdatedDate    = GETUTCDATE()
     WHERE ERM_NotificationOutboxID = @ERM_NotificationOutboxID;
END
GO

/* -----------------------------------------------------------------------------
   usp_Notification_ReleaseStale
   -----------------------------------------------------------------------------
   A dispatcher that is killed between claiming and reporting leaves rows in
   'sending' for ever. This puts anything older than @OlderThanMinutes back to
   'pending'.

   Run it before each dispatch pass. The window must be comfortably longer than
   a real send takes, or this will release rows that are still in flight and
   send them twice - which is the exact failure claiming exists to prevent.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE ERM.usp_Notification_ReleaseStale
(
    @OlderThanMinutes INT = 15
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @OlderThanMinutes IS NULL OR @OlderThanMinutes < 5 SET @OlderThanMinutes = 5;

    UPDATE ERM.ERM_NotificationOutbox
       SET DeliveryState = N'pending',
           ClaimedUtc    = NULL,
           ClaimedBy     = NULL,
           LastError     = CONCAT(N'Released after being stuck in sending since ',
                                  CONVERT(NVARCHAR(30), ClaimedUtc, 126),
                                  N' (claimed by ', ISNULL(ClaimedBy, N'unknown'), N')'),
           UpdatedBy     = ERM.fn_SystemUserID(),
           UpdatedDate   = GETUTCDATE()
     WHERE DeliveryState = N'sending'
       AND ClaimedUtc < DATEADD(MINUTE, -@OlderThanMinutes, SYSUTCDATETIME());

    SELECT @@ROWCOUNT AS Released;
END
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'013_notification_dispatch_api.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.5.0', ERM.fn_SystemUserID());
GO
