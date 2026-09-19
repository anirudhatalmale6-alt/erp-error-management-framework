/* =============================================================================
   ERP Error Management Framework
   Script 003 - Seed reference data (MERGE-based, re-runnable, non-destructive)

   Every value here is a starting point that an administrator can change from
   the admin console.  Re-running this script restores the shipped defaults for
   rows that are missing but never deletes rows you added.
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ------------------------------------------------------------- severity -- */
MERGE ERM.ERM_Severity AS t
USING (VALUES
    (1, N'critical', N'Critical', 1),
    (2, N'high',     N'High',     2),
    (3, N'medium',   N'Medium',   3),
    (4, N'low',      N'Low',      4),
    (5, N'info',     N'Information', 5)
) AS s (SeverityID, Code, DisplayName, RankOrder)
    ON t.SeverityID = s.SeverityID
WHEN NOT MATCHED THEN
    INSERT (SeverityID, Code, DisplayName, RankOrder, CreatedBy)
    VALUES (s.SeverityID, s.Code, s.DisplayName, s.RankOrder, ERM.fn_SystemUserID());
GO

/* ---------------------------------------------------------------- layer -- */
MERGE ERM.ERM_AppLayer AS t
USING (VALUES
    (1, N'angular',       N'Angular / front end'),
    (2, N'http',          N'HTTP / API transport'),
    (3, N'webapi',        N'ASP.NET Web API'),
    (4, N'business',      N'Business logic'),
    (5, N'data',          N'Data access'),
    (6, N'database',      N'SQL Server'),
    (7, N'integration',   N'External integration'),
    (8, N'infrastructure',N'Infrastructure / hosting')
) AS s (LayerID, Code, DisplayName)
    ON t.LayerID = s.LayerID
WHEN NOT MATCHED THEN
    INSERT (LayerID, Code, DisplayName, CreatedBy)
    VALUES (s.LayerID, s.Code, s.DisplayName, ERM.fn_SystemUserID());
GO

/* ------------------------------------------------------------- category -- */
/* These map 1:1 onto the error list in the brief.  DefaultSeverityID is what
   the classifier assigns when nothing more specific is known.                 */
MERGE ERM.ERM_ErrorCategory AS t
USING (VALUES
    (10, N'angular_runtime',   N'Angular runtime error',            2),
    (11, N'angular_render',    N'Template / rendering error',       2),
    (12, N'validation',        N'Form / validation error',          4),
    (13, N'submit_action',     N'Button / submit action error',     3),
    (14, N'lov_lookup',        N'LOV / lookup error',               3),
    (15, N'client_network',    N'Client network / offline',         3),
    (16, N'chunk_load',        N'Lazy chunk load failure',          2),
    (20, N'http_client',       N'HTTP 4xx (client)',                3),
    (21, N'http_server',       N'HTTP 5xx (server)',                2),
    (22, N'http_timeout',      N'HTTP timeout',                     2),
    (23, N'auth',              N'Authentication / authorisation',   3),
    (30, N'api_unhandled',     N'Unhandled .NET exception',         1),
    (31, N'business_rule',     N'Business rule violation',          4),
    (32, N'concurrency',       N'Concurrency / optimistic lock',    3),
    (33, N'serialization',     N'Serialisation / model binding',    3),
    (40, N'sql_error',         N'SQL Server error',                 1),
    (41, N'sql_procedure',     N'Stored procedure error',           1),
    (42, N'sql_constraint',    N'Constraint / referential integrity',3),
    (43, N'sql_deadlock',      N'Deadlock',                         2),
    (44, N'sql_timeout',       N'Query / command timeout',          2),
    (45, N'db_connection',     N'Database connection failure',      1),
    (50, N'integration',       N'External service failure',         2),
    (60, N'configuration',     N'Configuration error',              2),
    (99, N'unclassified',      N'Unclassified',                     3)
) AS s (CategoryID, Code, DisplayName, DefaultSeverityID)
    ON t.CategoryID = s.CategoryID
WHEN NOT MATCHED THEN
    INSERT (CategoryID, Code, DisplayName, DefaultSeverityID, CreatedBy)
    VALUES (s.CategoryID, s.Code, s.DisplayName, s.DefaultSeverityID, ERM.fn_SystemUserID());
GO

/* -------------------------------------------------------- ticket status -- */
MERGE ERM.ERM_TicketStatus AS t
USING (VALUES
    (1, N'new',         N'New',                     1, 1, 0, 0),
    (2, N'assigned',    N'Assigned',                2, 1, 0, 0),
    (3, N'in_progress', N'In Progress',             3, 1, 0, 0),
    (4, N'waiting_info',N'Waiting for Information', 4, 1, 0, 1),
    (5, N'resolved',    N'Resolved',                5, 1, 0, 0),
    (6, N'closed',      N'Closed',                  6, 0, 1, 0),
    (7, N'cancelled',   N'Cancelled',               7, 0, 1, 0),
    (8, N'reopened',    N'Reopened',                8, 1, 0, 0)
) AS s (StatusID, Code, DisplayName, RankOrder, IsOpen, IsTerminal, IsPaused)
    ON t.StatusID = s.StatusID
WHEN NOT MATCHED THEN
    INSERT (StatusID, Code, DisplayName, RankOrder, IsOpen, IsTerminal, IsPaused, CreatedBy)
    VALUES (s.StatusID, s.Code, s.DisplayName, s.RankOrder, s.IsOpen, s.IsTerminal, s.IsPaused, ERM.fn_SystemUserID());
GO

/* ---------------------------------------------------------- transitions -- */
/* New -> Assigned -> In Progress -> Waiting for Information -> Resolved -> Closed,
   plus the realistic side paths (cancel, reopen, resolve straight from In
   Progress, bounce back out of Waiting).                                      */
MERGE ERM.ERM_TicketStatusTransition AS t
USING (VALUES
    (1, 2, 0, 1),  (1, 3, 0, 1),  (1, 7, 1, 0),
    (2, 3, 0, 0),  (2, 4, 1, 0),  (2, 1, 1, 0),  (2, 7, 1, 0),
    (3, 4, 1, 0),  (3, 5, 1, 0),  (3, 2, 1, 0),  (3, 7, 1, 0),
    (4, 3, 0, 0),  (4, 5, 1, 0),  (4, 7, 1, 0),
    (5, 6, 0, 0),  (5, 8, 1, 0),
    (6, 8, 1, 0),
    (8, 2, 0, 1),  (8, 3, 0, 1),  (8, 5, 1, 0)
) AS s (FromStatusID, ToStatusID, RequiresComment, RequiresAssignee)
    ON t.FromStatusID = s.FromStatusID AND t.ToStatusID = s.ToStatusID
WHEN NOT MATCHED THEN
    INSERT (FromStatusID, ToStatusID, RequiresComment, RequiresAssignee, CreatedBy)
    VALUES (s.FromStatusID, s.ToStatusID, s.RequiresComment, s.RequiresAssignee, ERM.fn_SystemUserID());
GO

/* --------------------------------------------------------------- queues -- */
IF NOT EXISTS (SELECT 1 FROM ERM.ERM_TicketQueue WHERE Code = N'general')
    INSERT ERM.ERM_TicketQueue (Code, DisplayName, ErpModuleMatch, IsDefault, CreatedBy)
    VALUES (N'general', N'General Support', NULL, 1, ERM.fn_SystemUserID());
IF NOT EXISTS (SELECT 1 FROM ERM.ERM_TicketQueue WHERE Code = N'application')
    INSERT ERM.ERM_TicketQueue (Code, DisplayName, ErpModuleMatch, IsDefault, CreatedBy)
    VALUES (N'application', N'Application Support', NULL, 0, ERM.fn_SystemUserID());
IF NOT EXISTS (SELECT 1 FROM ERM.ERM_TicketQueue WHERE Code = N'database')
    INSERT ERM.ERM_TicketQueue (Code, DisplayName, ErpModuleMatch, IsDefault, CreatedBy)
    VALUES (N'database', N'Database Team', NULL, 0, ERM.fn_SystemUserID());
GO

/* ------------------------------------------------------------------ SLA -- */
MERGE ERM.ERM_SlaPolicy AS t
USING (VALUES
    (1, 15,  240),     -- critical: respond 15 min, resolve 4 h
    (2, 60,  480),     -- high
    (3, 240, 2880),    -- medium: 4 h / 2 days
    (4, 480, 10080),   -- low
    (5, 1440,43200)    -- info
) AS s (SeverityID, FirstResponseMinutes, ResolutionMinutes)
    ON t.SeverityID = s.SeverityID AND t.ERM_TicketQueueID IS NULL
WHEN NOT MATCHED THEN
    INSERT (SeverityID, ERM_TicketQueueID, FirstResponseMinutes, ResolutionMinutes, CreatedBy)
    VALUES (s.SeverityID, NULL, s.FirstResponseMinutes, s.ResolutionMinutes, ERM.fn_SystemUserID());
GO

/* ------------------------------------------------- redaction allow-list -- */
/* Only these keys survive capture with their real value; everything else in
   the same scope is stored as '***'.                                          */
MERGE ERM.ERM_RedactionAllowList AS t
USING (VALUES
    (N'header', N'content-type'),        (N'header', N'accept'),
    (N'header', N'accept-language'),     (N'header', N'user-agent'),
    (N'header', N'referer'),             (N'header', N'x-correlation-id'),
    (N'header', N'x-request-id'),        (N'header', N'x-erp-module'),
    (N'header', N'x-erp-screen'),        (N'header', N'x-app-version'),
    (N'query',  N'page'),                (N'query',  N'pageSize'),
    (N'query',  N'sort'),                (N'query',  N'sortDirection'),
    (N'query',  N'id'),                  (N'query',  N'code'),
    (N'query',  N'lovCode'),             (N'query',  N'moduleCode'),
    (N'query',  N'fromDate'),            (N'query',  N'toDate'),
    (N'body',   N'id'),                  (N'body',   N'code'),
    (N'body',   N'documentNo'),          (N'body',   N'status'),
    (N'body',   N'moduleCode'),          (N'body',   N'screenCode'),
    (N'body',   N'action'),              (N'body',   N'rowVersion'),
    (N'route',  N'id'),                  (N'route',  N'controller'),
    (N'route',  N'action')
) AS s (Scope, KeyName)
    ON t.Scope = s.Scope AND t.KeyName = s.KeyName
WHEN NOT MATCHED THEN
    INSERT (Scope, KeyName, CreatedBy) VALUES (s.Scope, s.KeyName, ERM.fn_SystemUserID());
GO

/* ------------------------------------------------------------- settings -- */
MERGE ERM.ERM_Setting AS t
USING (VALUES
    (N'capture.enabled',                  N'true',  N'bool', N'Master switch. false = the API accepts and discards envelopes.'),
    (N'capture.maxStackTraceChars',       N'20000', N'int',  N'Stack traces longer than this are truncated with a marker.'),
    (N'capture.maxBreadcrumbs',           N'25',    N'int',  N'Size of the client-side breadcrumb ring buffer.'),
    (N'capture.storeRequestBody',         N'true',  N'bool', N'Persist the (redacted) request body on the detail row.'),
    (N'capture.storeResponseBody',        N'false', N'bool', N'Off by default: responses are the likeliest place for bulk PII.'),
    (N'capture.sampling.infoPercent',     N'10',    N'int',  N'Percent of severity=info occurrences actually persisted.'),
    (N'dedup.windowMinutes',              N'60',    N'int',  N'Rolling window used by auto-ticket occurrence thresholds.'),
    (N'dedup.stackFrameDepth',            N'5',     N'int',  N'Frames included in the fingerprint signature.'),
    (N'ui.showErrorReference',            N'true',  N'bool', N'Show ERR-... in the modal even when no ticket is raised.'),
    (N'ui.allowUserDescription',          N'true',  N'bool', N'Let the user type what they were doing before submitting.'),
    (N'ui.suppressRepeatSeconds',         N'20',    N'int',  N'Do not re-open the modal for the same fingerprint within N seconds.'),
    (N'ticket.autoAssignToQueueOwner',    N'false', N'bool', N'Assign new tickets to the queue owner automatically.'),
    (N'ticket.reopenWindowDays',          N'14',    N'int',  N'A closed ticket can be reopened within this many days.'),
    (N'ticket.attachRecurrenceToOpen',    N'true',  N'bool', N'New occurrences of a fingerprint attach to its open ticket.'),
    (N'config.cacheSeconds',              N'300',   N'int',  N'How long the API caches these settings before re-reading.'),
    (N'notify.onStatusChange',            N'true',  N'bool', N'Emit a notification to the reporter on each visible change.')
) AS s (SettingKey, SettingValue, DataType, Description)
    ON t.SettingKey = s.SettingKey
WHEN NOT MATCHED THEN
    INSERT (SettingKey, SettingValue, DataType, Description, CreatedBy)
    VALUES (s.SettingKey, s.SettingValue, s.DataType, s.Description, ERM.fn_SystemUserID());
GO

/* -------------------------------------------------- auto-ticket rules ---- */
/* Shipped conservative on purpose: only a critical error that has already
   happened three times in an hour raises a ticket by itself.  Everything else
   waits for a human to press Report.                                          */
IF NOT EXISTS (SELECT 1 FROM ERM.ERM_AutoTicketRule WHERE RuleName = N'Critical recurring')
    INSERT ERM.ERM_AutoTicketRule (RuleName, MinSeverityID, MinOccurrences, WindowMinutes, TargetQueueID, CreatedBy)
    SELECT N'Critical recurring', 1, 3, 60, (SELECT ERM_TicketQueueID FROM ERM.ERM_TicketQueue WHERE Code = N'application'), ERM.fn_SystemUserID();
IF NOT EXISTS (SELECT 1 FROM ERM.ERM_AutoTicketRule WHERE RuleName = N'Database unavailable')
    INSERT ERM.ERM_AutoTicketRule (RuleName, CategoryID, MinOccurrences, WindowMinutes, TargetQueueID, CreatedBy)
    SELECT N'Database unavailable', 45, 1, 15, (SELECT ERM_TicketQueueID FROM ERM.ERM_TicketQueue WHERE Code = N'database'), ERM.fn_SystemUserID();
GO

/* ------------------------------------------------------------- retention -- */
MERGE ERM.ERM_RetentionPolicy AS t
USING (VALUES
    (N'occurrence_detail',  30,  0,    5000),  -- payloads archived after 30 days
    (N'occurrence',        180,  730,  5000),  -- events archived at 6 months, purged at 2 years
    (N'ticket',            365,  0,    2000),  -- closed tickets archived after a year, never purged
    (N'audit',             365,  0,    5000)
) AS s (DataSet, ArchiveAfterDays, PurgeAfterDays, BatchSize)
    ON t.DataSet = s.DataSet
WHEN NOT MATCHED THEN
    INSERT (DataSet, ArchiveAfterDays, PurgeAfterDays, BatchSize, CreatedBy)
    VALUES (s.DataSet, s.ArchiveAfterDays, s.PurgeAfterDays, s.BatchSize, ERM.fn_SystemUserID());
GO

MERGE ERM.ERM_SchemaVersion AS t
USING (SELECT N'003_seed_reference_data.sql' AS ScriptName) AS s
    ON t.ScriptName = s.ScriptName
WHEN NOT MATCHED THEN
    INSERT (ScriptName, FrameworkVersion, CreatedBy)
    VALUES (s.ScriptName, N'1.0.0', ERM.fn_SystemUserID());
GO
