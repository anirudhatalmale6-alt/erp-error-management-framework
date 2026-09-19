using System.Data;
using System.Text.Json;
using Erp.ErrorManagement;
using Microsoft.Data.Sqlite;

/// <summary>
/// SQLite mirror of the SQL Server schema and procedures in db/.
///
/// Every behaviour the brief cares about is implemented here with the SAME
/// semantics as the T-SQL, so the demo genuinely demonstrates the design rather
/// than a simplified version of it: fingerprint upsert with severity escalation,
/// attach-to-open-ticket deduplication, auto-ticket thresholds, workflow
/// transition validation, gapless audit history, minutes-in-status, paused
/// statuses excluded from active processing time, and SLA breach flags.
///
/// It is NOT the production store.  See the banner in Program.cs.
/// </summary>
public class ErrorQuery
{
    public string? Severity { get; set; }
    public string? Layer { get; set; }
    public string? Category { get; set; }
    public string? ErpModule { get; set; }
    public string? UserName { get; set; }
    public string? ErrorReference { get; set; }
    public string? CorrelationId { get; set; }
    public long? FingerprintId { get; set; }
    public string? FromUtc { get; set; }
    public string? ToUtc { get; set; }
    public string? SearchText { get; set; }
    public bool? OnlyUnticketed { get; set; }
    public string? SortBy { get; set; }
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

public class ProblemQuery
{
    public string? FromUtc { get; set; }
    public int MinOccurrences { get; set; } = 1;
    public string? Severity { get; set; }
    public string? Layer { get; set; }
    public string? ErpModule { get; set; }
    public bool? IncludeMuted { get; set; }
    public string? SortBy { get; set; }
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

public class DemoStore
{
    private readonly string _connectionString;
    private readonly object _writeLock = new();

    public DemoStore(string connectionString) => _connectionString = connectionString;

    private SqliteConnection Open()
    {
        var c = new SqliteConnection(_connectionString);
        c.Open();
        using var pragma = c.CreateCommand();
        pragma.CommandText = "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;";
        pragma.ExecuteNonQuery();
        return c;
    }

    public void Initialise()
    {
        using var c = Open();
        Exec(c, """
            CREATE TABLE IF NOT EXISTS Fingerprint (
              FingerprintId INTEGER PRIMARY KEY AUTOINCREMENT,
              FingerprintHash TEXT NOT NULL UNIQUE,
              SignatureText TEXT, Layer TEXT, Category TEXT, Severity TEXT,
              ExceptionType TEXT, NormalizedMessage TEXT,
              ErpModule TEXT, Screen TEXT, Component TEXT, ApiEndpoint TEXT, SqlObjectName TEXT,
              FirstSeenUtc TEXT, LastSeenUtc TEXT,
              OccurrenceCount INTEGER NOT NULL DEFAULT 0,
              DistinctUserCount INTEGER NOT NULL DEFAULT 0,
              TriageState TEXT NOT NULL DEFAULT 'new',
              OpenTicketId INTEGER
            );

            CREATE TABLE IF NOT EXISTS Occurrence (
              OccurrenceId INTEGER PRIMARY KEY AUTOINCREMENT,
              ErrorReference TEXT NOT NULL UNIQUE,
              FingerprintId INTEGER NOT NULL,
              OccurredUtc TEXT NOT NULL,
              Layer TEXT, Category TEXT, Severity TEXT,
              ExceptionType TEXT, Message TEXT,
              ErpModule TEXT, Screen TEXT, RouteUrl TEXT, Component TEXT,
              ActionName TEXT, FormName TEXT, LovName TEXT,
              ApiController TEXT, ApiAction TEXT, ApiEndpoint TEXT,
              HttpMethod TEXT, HttpStatusCode INTEGER,
              SqlErrorNumber INTEGER, SqlObjectName TEXT, SqlLineNumber INTEGER,
              SqlServerName TEXT, SqlDatabaseName TEXT, SqlSchemaName TEXT,
              UserProfileId INTEGER NOT NULL DEFAULT -1, UserName TEXT, UserDisplayName TEXT,
              CorrelationId TEXT, RequestId TEXT,
              Environment TEXT, AppVersion TEXT,
              BrowserName TEXT, BrowserVersion TEXT, OsName TEXT,
              StackTrace TEXT, InnerExceptionChain TEXT,
              RequestPayloadJson TEXT, ValidationErrorsJson TEXT, BreadcrumbsJson TEXT,
              TicketId INTEGER
            );

            CREATE TABLE IF NOT EXISTS Ticket (
              TicketId INTEGER PRIMARY KEY AUTOINCREMENT,
              TicketNumber TEXT NOT NULL UNIQUE,
              OccurrenceId INTEGER, FingerprintId INTEGER,
              Status TEXT NOT NULL, Severity TEXT, Queue TEXT,
              Title TEXT, UserDescription TEXT,
              ReportedByUserProfileId INTEGER NOT NULL DEFAULT -1, ReportedByUserName TEXT,
              AssignedToUserProfileId INTEGER, AssignedToUserName TEXT, CreatedVia TEXT,
              ErpModule TEXT, Environment TEXT,
              CreatedUtc TEXT, FirstResponseUtc TEXT, AssignedUtc TEXT,
              ResolvedUtc TEXT, ClosedUtc TEXT, LastStatusChangeUtc TEXT,
              TotalElapsedMinutes INTEGER, ActiveProcessingMinutes INTEGER,
              SlaFirstResponseMinutes INTEGER, SlaResolutionMinutes INTEGER,
              SlaFirstResponseBreached INTEGER NOT NULL DEFAULT 0,
              SlaResolutionBreached INTEGER NOT NULL DEFAULT 0,
              ReopenCount INTEGER NOT NULL DEFAULT 0,
              LinkedOccurrenceCount INTEGER NOT NULL DEFAULT 1,
              ResolutionCode TEXT, ResolutionNotes TEXT,
              TicketSource TEXT NOT NULL DEFAULT 'error',
              RequestCategory TEXT, ReportedScreen TEXT
            );

            CREATE TABLE IF NOT EXISTS TicketHistory (
              HistoryId INTEGER PRIMARY KEY AUTOINCREMENT,
              TicketId INTEGER NOT NULL, SequenceNo INTEGER NOT NULL,
              FromStatus TEXT, ToStatus TEXT NOT NULL,
              ChangedByUserProfileId INTEGER NOT NULL DEFAULT -1, ChangedByUserName TEXT,
              ChangedUtc TEXT NOT NULL,
              MinutesInFromStatus INTEGER, Comments TEXT,
              AssignedToUserProfileId INTEGER, AssignedToUserName TEXT,
              PreviousAssignedToUserName TEXT,
              ChangeKind TEXT NOT NULL DEFAULT 'status',
              IsCustomerVisible INTEGER NOT NULL DEFAULT 1
            );

            CREATE TABLE IF NOT EXISTS TicketComment (
              CommentId INTEGER PRIMARY KEY AUTOINCREMENT,
              TicketId INTEGER NOT NULL,
              AuthorUserProfileId INTEGER NOT NULL DEFAULT -1, AuthorUserName TEXT,
              AuthorRole TEXT NOT NULL DEFAULT 'support',
              CommentText TEXT NOT NULL,
              IsCustomerVisible INTEGER NOT NULL DEFAULT 1,
              CreatedUtc TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS TicketLink (
              TicketId INTEGER NOT NULL, OccurrenceId INTEGER NOT NULL,
              LinkReason TEXT, LinkedUtc TEXT,
              PRIMARY KEY (TicketId, OccurrenceId)
            );

            CREATE TABLE IF NOT EXISTS SupportUser (
              UserProfileId INTEGER PRIMARY KEY,
              UserName TEXT,
              DisplayName TEXT NOT NULL,
              RoleCode TEXT NOT NULL,
              IsAvailable INTEGER NOT NULL DEFAULT 1,
              IsActive INTEGER NOT NULL DEFAULT 1
            );

            CREATE TABLE IF NOT EXISTS Counter (Name TEXT PRIMARY KEY, Value INTEGER NOT NULL);
            """);
    }

    public void Reset()
    {
        lock (_writeLock)
        {
            using var c = Open();
            Exec(c, "DELETE FROM TicketLink; DELETE FROM TicketHistory; DELETE FROM Ticket; " +
                    "DELETE FROM Occurrence; DELETE FROM Fingerprint; DELETE FROM Counter;");
        }
    }

    /* ==================================================================== */
    /*  Reference data - the rows that live in ERM.* config tables      */
    /* ==================================================================== */

    // Mirrors ERM.ERM_TicketStatus.  IsPaused time is excluded from active
    // processing minutes; IsTerminal blocks further transitions.
    private static readonly Dictionary<string, (string Display, bool IsOpen, bool IsTerminal, bool IsPaused, int Rank)> Statuses
        = new(StringComparer.OrdinalIgnoreCase)
        {
            ["new"] = ("New", true, false, false, 1),
            ["assigned"] = ("Assigned", true, false, false, 2),
            ["in_progress"] = ("In Progress", true, false, false, 3),
            ["waiting_info"] = ("Waiting for Information", true, false, true, 4),
            ["resolved"] = ("Resolved", true, false, false, 5),
            ["closed"] = ("Closed", false, true, false, 6),
            ["cancelled"] = ("Cancelled", false, true, false, 7),
            ["reopened"] = ("Reopened", true, false, false, 8),
        };

    // Mirrors ERM.ERM_TicketStatusTransition.  (from, to) -> requires comment.
    private static readonly Dictionary<(string, string), bool> Transitions = new()
    {
        [("new", "assigned")] = false, [("new", "in_progress")] = false, [("new", "cancelled")] = true,
        [("assigned", "in_progress")] = false, [("assigned", "waiting_info")] = true,
        [("assigned", "new")] = true, [("assigned", "cancelled")] = true,
        [("in_progress", "waiting_info")] = true, [("in_progress", "resolved")] = true,
        [("in_progress", "assigned")] = true, [("in_progress", "cancelled")] = true,
        [("waiting_info", "in_progress")] = false, [("waiting_info", "resolved")] = true,
        [("waiting_info", "cancelled")] = true,
        [("resolved", "closed")] = false, [("resolved", "reopened")] = true,
        [("closed", "reopened")] = true,
        [("reopened", "assigned")] = false, [("reopened", "in_progress")] = false,
        [("reopened", "resolved")] = true,
    };

    /// <summary>Mirrors ERM.ERM_SupportRole - capability flags, not a hierarchy.</summary>
    private static readonly Dictionary<string, (string Name, bool View, bool Diag, bool Manage,
        bool Assignable, bool Triage, bool Configure)> Roles = new(StringComparer.OrdinalIgnoreCase)
    {
        ["support_agent"]  = ("Support Agent",  true, true,  true,  true,  false, false),
        ["support_lead"]   = ("Support Lead",   true, true,  true,  true,  true,  false),
        ["developer"]      = ("Developer",      true, true,  true,  true,  true,  false),
        ["support_viewer"] = ("Support Viewer", true, false, false, false, false, false),
        ["administrator"]  = ("Administrator",  true, true,  true,  true,  true,  true),
    };

    /// <summary>
    /// The demo's stand-in for the ERP's user directory.
    ///
    /// Production never needs this: the UserProfileID arrives on the request,
    /// already resolved, from generic_service.GetUserProfileKey() on the way in.
    /// The demo has a name in a header because a name is easier to type into
    /// curl, so it resolves that name to an id ONCE, at the edge, and everything
    /// below this line is keyed on the integer - exactly as the real schema is.
    /// </summary>
    public static readonly Dictionary<string, int> DemoUserProfileIds =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["fatima.saeed"] = 10427,
            ["omar.khan"]    = 10428,
            ["lisa.chen"]    = 10429,
            ["raj.patel"]    = 10430,
            ["sam.ops"]      = 20001,
            ["dev.patel"]    = 20002,
            ["ana.silva"]    = 20003,
            ["mgr.khoury"]   = 20004,
        };

    public const int NoUser = -1;

    public static int ProfileIdOf(string? userName) =>
        userName is not null && DemoUserProfileIds.TryGetValue(userName, out var id) ? id : NoUser;

    public static string? NameOf(int userProfileId) =>
        DemoUserProfileIds.FirstOrDefault(kv => kv.Value == userProfileId).Key;

    /// <summary>
    /// Mirrors ERM.fn_SupportCapability. FAILS CLOSED - no roster row means
    /// no capability, and an unknown capability name grants nothing. -1 is
    /// refused outright, so an anonymous caller can never be support.
    /// </summary>
    public object WhoAmI(int userProfileId)
    {
        using var c = Open();
        var row = userProfileId > 0
            ? QueryOne(c, null,
                "SELECT * FROM SupportUser WHERE UserProfileId = $u AND IsActive = 1", ("$u", userProfileId))
            : null;

        // The name is returned even when access is refused: the console shows
        // "Signed in as <name>" on the denial screen, so leaving it out turns a
        // clear message into "Signed in as ." with a gap where the name was.
        if (row is null || !Roles.TryGetValue((string)row["RoleCode"]!, out var r))
            return new { isSupportUser = false, userProfileId, userName = NameOf(userProfileId) };

        return new
        {
            isSupportUser = true,
            userProfileId,
            userName = row["UserName"],
            displayName = row["DisplayName"],
            roleCode = row["RoleCode"],
            roleName = r.Name,
            canViewErrors = r.View,
            canViewDiagnostics = r.Diag,
            canManageTickets = r.Manage,
            canBeAssigned = r.Assignable,
            canTriage = r.Triage,
            canConfigure = r.Configure,
            isAvailable = Convert.ToInt64(row["IsAvailable"]) == 1,
        };
    }

    public bool HasCapability(int userProfileId, string capability)
    {
        // Mirrors the SQL predicate: NULL and -1 are both "not a user".
        if (userProfileId <= 0) return false;

        using var c = Open();
        var row = QueryOne(c, null,
            "SELECT RoleCode FROM SupportUser WHERE UserProfileId = $u AND IsActive = 1", ("$u", userProfileId));
        if (row is null || !Roles.TryGetValue((string)row["RoleCode"]!, out var r)) return false;

        return capability switch
        {
            "view" => r.View,
            "diagnostics" => r.Diag,
            "manage" => r.Manage,
            "triage" => r.Triage,
            "configure" => r.Configure,
            _ => false,
        };
    }

    public object ListAssignable()
    {
        using var c = Open();
        var rows = Query(c, null, "SELECT * FROM SupportUser WHERE IsActive = 1 AND IsAvailable = 1");

        var items = rows
            .Where(r => Roles.TryGetValue((string)r["RoleCode"]!, out var x) && x.Assignable)
            .Select(r => new
            {
                userProfileId = Convert.ToInt32(r["UserProfileId"]),
                userName = r["UserName"],
                displayName = r["DisplayName"],
                roleCode = r["RoleCode"],
                roleName = Roles[(string)r["RoleCode"]!].Name,
                isAvailable = true,
                openTicketCount = ExecScalarLong(c, null,
                    "SELECT COUNT(*) FROM Ticket WHERE AssignedToUserProfileId = $u AND Status IN "
                    + "('new','assigned','in_progress','waiting_info','resolved','reopened')",
                    ("$u", r["UserProfileId"])),
            })
            // Least-loaded first, so a lead is not assigning alphabetically.
            .OrderBy(x => x.openTicketCount).ThenBy(x => x.displayName)
            .ToList();

        return new { items, total = items.Count };
    }

    /// <summary>
    /// Mirrors usp_Ticket_Assign: validated against the roster, audited every
    /// time, and works WITHOUT a status change - so a reassignment leaves a
    /// trace too, which it previously did not, because it is not a transition.
    /// </summary>
    public object? AssignTicket(string ticketNumber, int? assignToProfileId, int changedByProfileId,
        string? comments)
    {
        lock (_writeLock)
        {
            using var c = Open();

            if (!HasCapability(changedByProfileId, "manage")) return null;

            var t = QueryOne(c, null,
                "SELECT TicketId, Status, AssignedToUserProfileId, AssignedToUserName FROM Ticket WHERE TicketNumber = $n",
                ("$n", ticketNumber));
            if (t is null) return null;

            var ticketId = Convert.ToInt64(t["TicketId"]);
            var status = (string)t["Status"]!;
            var previous = t["AssignedToUserName"] as string;

            string? targetDisplay = null;
            string? targetName = null;
            if (assignToProfileId is > 0)
            {
                var su = QueryOne(c, null,
                    "SELECT UserName, DisplayName, RoleCode FROM SupportUser WHERE UserProfileId = $u AND IsActive = 1",
                    ("$u", assignToProfileId.Value));
                // An unvalidated assignee looks harmless until the first wrong
                // id, after which the ticket belongs to nobody and shows in no
                // queue.
                if (su is null) return null;
                if (!Roles.TryGetValue((string)su["RoleCode"]!, out var role) || !role.Assignable) return null;
                targetDisplay = (string)su["DisplayName"]!;
                targetName = su["UserName"] as string;
            }

            var now = DateTime.UtcNow;

            Exec(c, null,
                "UPDATE Ticket SET AssignedToUserProfileId = $toid, AssignedToUserName = $to, "
                + "AssignedUtc = CASE WHEN $toid IS NULL THEN NULL ELSE COALESCE(AssignedUtc, $now) END, "
                + "FirstResponseUtc = CASE WHEN $toid IS NULL THEN FirstResponseUtc "
                + "ELSE COALESCE(FirstResponseUtc, $now) END WHERE TicketId = $t",
                ("$toid", assignToProfileId is > 0 ? assignToProfileId.Value : (object?)null),
                ("$to", targetName), ("$now", Iso(now)), ("$t", ticketId));

            var seq = ExecScalarLong(c, null,
                "SELECT COALESCE(MAX(SequenceNo),0) + 1 FROM TicketHistory WHERE TicketId = $t",
                ("$t", ticketId));

            var note = comments ?? (targetDisplay is null ? "Ticket unassigned."
                : previous is null ? $"Assigned to {targetDisplay}."
                : $"Reassigned from {previous} to {targetDisplay}.");

            Exec(c, null,
                "INSERT INTO TicketHistory (TicketId, SequenceNo, FromStatus, ToStatus, "
                + "ChangedByUserProfileId, ChangedByUserName, ChangedUtc, MinutesInFromStatus, Comments, "
                + "AssignedToUserProfileId, AssignedToUserName, PreviousAssignedToUserName, ChangeKind, IsCustomerVisible) "
                + "VALUES ($t,$seq,$st,$st,$byid,$by,$now,NULL,$c,$toid,$to,$prev,'assignment',0)",
                ("$t", ticketId), ("$seq", seq), ("$st", status),
                ("$byid", changedByProfileId), ("$by", NameOf(changedByProfileId)),
                ("$now", Iso(now)), ("$c", note),
                ("$toid", assignToProfileId is > 0 ? assignToProfileId.Value : (object?)null),
                ("$to", targetName), ("$prev", previous));

            // Advance New -> Assigned as its own validated transition, so the
            // status history and minutes-in-status accounting stay correct.
            if (assignToProfileId is > 0 && status.Equals("new", StringComparison.OrdinalIgnoreCase)
                && Transitions.ContainsKey(("new", "assigned")))
            {
                try
                {
                    ChangeStatus(ticketNumber, "assigned", changedByProfileId, "Assigned.",
                        assignToProfileId);
                }
                catch (InvalidOperationException) { /* the workflow is the authority */ }
            }

            return new
            {
                ticketNumber, assignedTo = targetName, assignedToProfileId = assignToProfileId,
                assignedToName = targetDisplay,
                previousAssignedTo = previous, sequenceNo = seq
            };
        }
    }

    public object RequestCategories() => new
    {
        items = new[]
        {
            new { code = "wrong_data",      displayName = "Data looks wrong or is missing" },
            new { code = "cannot_complete", displayName = "I cannot complete a task" },
            new { code = "slow",            displayName = "Something is very slow" },
            new { code = "access",          displayName = "I need access to something" },
            new { code = "how_to",          displayName = "I need help using a screen" },
            new { code = "enhancement",     displayName = "Suggestion or enhancement request" },
            new { code = "other",           displayName = "Something else" },
        }
    };

    private static readonly Dictionary<string, string> CategorySeverity = new()
    {
        ["wrong_data"] = "medium", ["cannot_complete"] = "high", ["slow"] = "medium",
        ["access"] = "low", ["how_to"] = "low", ["enhancement"] = "info", ["other"] = "low",
    };

    /// <summary>
    /// Mirrors usp_Ticket_CreateManual. NOT deduplicated: there is no fault to
    /// fingerprint, and two people describing the same annoyance in their own
    /// words are two requests, not one.
    ///
    /// Severity comes from the CATEGORY, not from the user - otherwise everyone
    /// marks their request critical and the SLA queue means nothing.
    /// </summary>
    public object? CreateManualTicket(string title, string? description, string? category,
        string? erpModule, string? screen, int reportedByProfileId)
    {
        // -1 counts as unowned: the non-user value is not somebody who can be
        // asked for more information, so the ticket would be a dead record.
        if (string.IsNullOrWhiteSpace(title) || reportedByProfileId <= 0) return null;

        lock (_writeLock)
        {
            using var c = Open();
            var now = DateTime.UtcNow;
            var cat = category is not null && CategorySeverity.ContainsKey(category) ? category : "other";
            var severity = CategorySeverity[cat];
            var sla = Sla.TryGetValue(severity, out var s2) ? s2 : Sla["low"];
            var ticketNumber = NextReference(c, null, "TKT", now);

            var ticketId = ExecScalarLong(c, null,
                "INSERT INTO Ticket (TicketNumber, OccurrenceId, FingerprintId, Status, Severity, Queue, "
                + "Title, UserDescription, ReportedByUserProfileId, ReportedByUserName, CreatedVia, ErpModule, Environment, "
                + "CreatedUtc, LastStatusChangeUtc, SlaFirstResponseMinutes, SlaResolutionMinutes, "
                + "LinkedOccurrenceCount, TicketSource, RequestCategory, ReportedScreen) "
                + "VALUES ($num,NULL,NULL,'new',$sev,'general',$title,$desc,$byid,$by,'user',$mod,'Demo',"
                + "$now,$now,$fr,$res,0,'manual',$cat,$screen); SELECT last_insert_rowid();",
                ("$num", ticketNumber), ("$sev", severity),
                ("$title", Redactor.ScrubText(title, 400)),
                ("$desc", Redactor.ScrubText(description, 8000)),
                ("$byid", reportedByProfileId), ("$by", NameOf(reportedByProfileId)),
                ("$mod", erpModule), ("$now", Iso(now)),
                ("$fr", sla.FirstResponse), ("$res", sla.Resolution),
                ("$cat", cat), ("$screen", screen));

            Exec(c, null,
                "INSERT INTO TicketHistory (TicketId, SequenceNo, FromStatus, ToStatus, "
                + "ChangedByUserProfileId, ChangedByUserName, ChangedUtc, MinutesInFromStatus, Comments, ChangeKind, IsCustomerVisible) "
                + "VALUES ($t,1,NULL,'new',$byid,$by,$now,NULL,'Ticket raised manually by the user.','status',1)",
                ("$t", ticketId), ("$byid", reportedByProfileId),
                ("$by", NameOf(reportedByProfileId)), ("$now", Iso(now)));

            return new { ticketNumber, ticketId, wasDeduplicated = false };
        }
    }

    // Mirrors ERM.ERM_SlaPolicy.
    private static readonly Dictionary<string, (int FirstResponse, int Resolution)> Sla = new()
    {
        ["critical"] = (15, 240), ["high"] = (60, 480), ["medium"] = (240, 2880),
        ["low"] = (480, 10080), ["info"] = (1440, 43200),
    };

    private static readonly string[] SeverityRank = { "critical", "high", "medium", "low", "info" };
    private static int Rank(string severity) => Array.IndexOf(SeverityRank, severity ?? "medium") is var i && i >= 0 ? i : 2;

    /* ==================================================================== */
    /*  usp_Error_Capture                                                   */
    /* ==================================================================== */

    public ErrorCaptureResult? Capture(ErrorEnvelope envelope)
    {
        if (envelope?.FingerprintHash is null || envelope.FingerprintHash.Length != 64)
            return null;

        lock (_writeLock)
        {
            using var c = Open();
            using var tx = c.BeginTransaction();

            var now = DateTime.UtcNow;
            var occurredUtc = ParseUtc(envelope.OccurredUtc) ?? now;
            // Clamp a wrong client clock, exactly as the T-SQL does.
            if (occurredUtc > now.AddMinutes(5) || occurredUtc < now.AddYears(-1)) occurredUtc = now;

            var severity = envelope.Severity ?? "medium";

            // --- fingerprint upsert, with severity escalation only ----------
            var existing = QueryOne(c, tx,
                "SELECT FingerprintId, Severity, TriageState, OpenTicketId, LastSeenUtc FROM Fingerprint WHERE FingerprintHash = $h",
                ("$h", envelope.FingerprintHash));

            long fingerprintId;
            string triageState;
            long? openTicketId = null;

            if (existing is null)
            {
                fingerprintId = ExecScalarLong(c, tx, """
                    INSERT INTO Fingerprint (FingerprintHash, SignatureText, Layer, Category, Severity,
                      ExceptionType, NormalizedMessage, ErpModule, Screen, Component, ApiEndpoint,
                      SqlObjectName, FirstSeenUtc, LastSeenUtc, OccurrenceCount, DistinctUserCount)
                    VALUES ($h,$sig,$layer,$cat,$sev,$type,$nmsg,$mod,$scr,$cmp,$ep,$sqlobj,$first,$last,1,0);
                    SELECT last_insert_rowid();
                    """,
                    ("$h", envelope.FingerprintHash), ("$sig", envelope.SignatureText),
                    ("$layer", envelope.Layer), ("$cat", envelope.Category), ("$sev", severity),
                    ("$type", envelope.ExceptionType),
                    ("$nmsg", envelope.NormalizedMessage ?? envelope.Message),
                    ("$mod", envelope.ErpModule), ("$scr", envelope.Screen),
                    ("$cmp", envelope.Component), ("$ep", envelope.ApiEndpoint),
                    ("$sqlobj", envelope.Sql?.ObjectName),
                    ("$first", Iso(occurredUtc)), ("$last", Iso(occurredUtc)));
                triageState = "new";
            }
            else
            {
                fingerprintId = Convert.ToInt64(existing["FingerprintId"]);
                var storedSeverity = existing["Severity"] as string ?? severity;
                // Escalate, never de-escalate.
                var effective = Rank(severity) < Rank(storedSeverity) ? severity : storedSeverity;
                var lastSeen = ParseUtc(existing["LastSeenUtc"] as string) ?? occurredUtc;

                Exec(c, tx, "UPDATE Fingerprint SET OccurrenceCount = OccurrenceCount + 1, " +
                            "LastSeenUtc = $last, Severity = $sev WHERE FingerprintId = $id",
                    ("$last", Iso(occurredUtc > lastSeen ? occurredUtc : lastSeen)),
                    ("$sev", effective), ("$id", fingerprintId));

                triageState = existing["TriageState"] as string ?? "new";
                openTicketId = existing["OpenTicketId"] is null
                    ? null : Convert.ToInt64(existing["OpenTicketId"]);
                severity = effective;
            }

            // --- occurrence -------------------------------------------------
            var reference = NextReference(c, tx, "ERR", now);

            var occurrenceId = ExecScalarLong(c, tx, """
                INSERT INTO Occurrence (ErrorReference, FingerprintId, OccurredUtc, Layer, Category,
                  Severity, ExceptionType, Message, ErpModule, Screen, RouteUrl, Component,
                  ActionName, FormName, LovName, ApiController, ApiAction, ApiEndpoint,
                  HttpMethod, HttpStatusCode, SqlErrorNumber, SqlObjectName, SqlLineNumber,
                  SqlServerName, SqlDatabaseName, SqlSchemaName, UserProfileId, UserName, UserDisplayName,
                  CorrelationId, RequestId, Environment, AppVersion,
                  BrowserName, BrowserVersion, OsName,
                  StackTrace, InnerExceptionChain, RequestPayloadJson, ValidationErrorsJson, BreadcrumbsJson)
                VALUES ($ref,$fp,$occ,$layer,$cat,$sev,$type,$msg,$mod,$scr,$route,$cmp,
                  $act,$form,$lov,$ctrl,$action,$ep,$method,$status,$sqlnum,$sqlobj,$sqlline,
                  $sqlsrv,$sqldb,$sqlschema,$userid,$user,$display,$corr,$req,$env,$ver,
                  $browser,$bver,$os,$stack,$inner,$payload,$val,$crumbs);
                SELECT last_insert_rowid();
                """,
                ("$ref", reference), ("$fp", fingerprintId), ("$occ", Iso(occurredUtc)),
                ("$layer", envelope.Layer), ("$cat", envelope.Category), ("$sev", envelope.Severity),
                ("$type", envelope.ExceptionType), ("$msg", envelope.Message),
                ("$mod", envelope.ErpModule), ("$scr", envelope.Screen),
                ("$route", envelope.RouteUrl), ("$cmp", envelope.Component),
                ("$act", envelope.ActionName), ("$form", envelope.FormName), ("$lov", envelope.LovName),
                ("$ctrl", envelope.ApiController), ("$action", envelope.ApiAction),
                ("$ep", envelope.ApiEndpoint), ("$method", envelope.HttpMethod),
                ("$status", envelope.HttpStatusCode),
                ("$sqlnum", envelope.Sql?.Number), ("$sqlobj", envelope.Sql?.ObjectName),
                ("$sqlline", envelope.Sql?.LineNumber), ("$sqlsrv", envelope.Sql?.ServerName),
                ("$sqldb", envelope.Sql?.DatabaseName), ("$sqlschema", envelope.Sql?.SchemaName),
                ("$userid", envelope.User?.ProfileId is int pid && pid > 0 ? pid : NoUser),
                ("$user", envelope.User?.Name), ("$display", envelope.User?.DisplayName),
                ("$corr", envelope.CorrelationId), ("$req", envelope.RequestId),
                ("$env", envelope.Environment), ("$ver", envelope.AppVersion),
                ("$browser", envelope.Client?.BrowserName), ("$bver", envelope.Client?.BrowserVersion),
                ("$os", envelope.Client?.OsName),
                ("$stack", envelope.StackTrace), ("$inner", envelope.InnerExceptionChain),
                ("$payload", Json(envelope.RequestPayload)),
                ("$val", Json(envelope.ValidationErrors)), ("$crumbs", Json(envelope.Breadcrumbs)));

            // Incremental distinct-user count, on the UserProfileID rather than
            // the name. Two people can share a display name and one person can
            // have theirs corrected; either would quietly corrupt "how many
            // users does this affect", which is the number that decides whether
            // a problem gets fixed. -1 is excluded, or every anonymous visitor
            // would look like the same one user.
            if (envelope.User?.ProfileId is int userPid && userPid > 0)
            {
                var seenBefore = ExecScalarLong(c, tx,
                    "SELECT COUNT(*) FROM Occurrence WHERE FingerprintId = $fp AND UserProfileId = $u AND OccurrenceId <> $id",
                    ("$fp", fingerprintId), ("$u", userPid), ("$id", occurrenceId));
                if (seenBefore == 0)
                    Exec(c, tx, "UPDATE Fingerprint SET DistinctUserCount = DistinctUserCount + 1 WHERE FingerprintId = $fp",
                        ("$fp", fingerprintId));
            }

            // --- attach to an already-open ticket for the same problem ------
            string? autoTicketNumber = null;

            if (openTicketId is long openId && IsTicketOpen(c, tx, openId))
            {
                Exec(c, tx, "INSERT OR IGNORE INTO TicketLink (TicketId, OccurrenceId, LinkReason, LinkedUtc) " +
                            "VALUES ($t,$o,'deduplicated',$at)",
                    ("$t", openId), ("$o", occurrenceId), ("$at", Iso(now)));
                Exec(c, tx, "UPDATE Ticket SET LinkedOccurrenceCount = LinkedOccurrenceCount + 1 WHERE TicketId = $t",
                    ("$t", openId));
                Exec(c, tx, "UPDATE Occurrence SET TicketId = $t WHERE OccurrenceId = $o",
                    ("$t", openId), ("$o", occurrenceId));
                autoTicketNumber = QueryOne(c, tx, "SELECT TicketNumber FROM Ticket WHERE TicketId = $t",
                    ("$t", openId))?["TicketNumber"] as string;
            }

            tx.Commit();

            // --- auto-ticket rules, outside the capture transaction ---------
            // Shipped rule: a CRITICAL problem seen 3+ times in an hour raises
            // its own ticket without waiting for a user to press Report.
            if (autoTicketNumber is null && triageState != "muted" && severity == "critical")
            {
                var recent = CountRecent(fingerprintId, now.AddMinutes(-60));
                if (recent >= 3)
                {
                    // No person behind an automatic rule: -1, not a made-up
                    // "system" user who would then appear to own the ticket.
                    var created = CreateTicket(reference, null, NoUser, "auto_rule");
                    autoTicketNumber = created?.TicketNumber;
                }
            }

            return new ErrorCaptureResult
            {
                ErrorReference = reference,
                OccurrenceId = occurrenceId,
                FingerprintId = fingerprintId,
                ShouldNotifyUser = triageState != "muted",
                AutoTicketNumber = autoTicketNumber,
                IsKnownIssue = triageState is "known_issue" or "muted"
            };
        }
    }

    private long CountRecent(long fingerprintId, DateTime since)
    {
        using var c = Open();
        return ExecScalarLong(c, null,
            "SELECT COUNT(*) FROM Occurrence WHERE FingerprintId = $fp AND OccurredUtc >= $since",
            ("$fp", fingerprintId), ("$since", Iso(since)));
    }

    /* ==================================================================== */
    /*  usp_Ticket_Create                                                   */
    /* ==================================================================== */

    public TicketCreateResult? CreateTicket(string errorReference, string? description,
        int reportedByProfileId, string createdVia)
    {
        lock (_writeLock)
        {
            using var c = Open();
            using var tx = c.BeginTransaction();

            var occ = QueryOne(c, tx, """
                SELECT OccurrenceId, FingerprintId, Severity, ErpModule, Environment, Message, Screen
                FROM Occurrence WHERE ErrorReference = $ref
                """, ("$ref", errorReference));
            if (occ is null) return null;

            var occurrenceId = Convert.ToInt64(occ["OccurrenceId"]);
            var fingerprintId = Convert.ToInt64(occ["FingerprintId"]);
            var severity = occ["Severity"] as string ?? "medium";
            var now = DateTime.UtcNow;

            // Already an open ticket for this problem?  Attach, do not duplicate.
            var fp = QueryOne(c, tx, "SELECT OpenTicketId FROM Fingerprint WHERE FingerprintId = $fp",
                ("$fp", fingerprintId));
            var openTicketId = fp?["OpenTicketId"] is null ? (long?)null
                : Convert.ToInt64(fp!["OpenTicketId"]);

            if (openTicketId is long existingId && IsTicketOpen(c, tx, existingId))
            {
                Exec(c, tx, "INSERT OR IGNORE INTO TicketLink (TicketId, OccurrenceId, LinkReason, LinkedUtc) " +
                            "VALUES ($t,$o,'deduplicated',$at)",
                    ("$t", existingId), ("$o", occurrenceId), ("$at", Iso(now)));
                Exec(c, tx, "UPDATE Ticket SET LinkedOccurrenceCount = LinkedOccurrenceCount + 1 WHERE TicketId = $t",
                    ("$t", existingId));
                Exec(c, tx, "UPDATE Occurrence SET TicketId = $t WHERE OccurrenceId = $o",
                    ("$t", existingId), ("$o", occurrenceId));

                var number = QueryOne(c, tx, "SELECT TicketNumber FROM Ticket WHERE TicketId = $t",
                    ("$t", existingId))?["TicketNumber"] as string;
                tx.Commit();

                return new TicketCreateResult
                {
                    TicketNumber = number!, TicketId = existingId, WasDeduplicated = true
                };
            }

            var ticketNumber = NextReference(c, tx, "TKT", now);
            var sla = Sla.TryGetValue(severity, out var s) ? s : Sla["medium"];

            var title = Truncate(
                $"{occ["ErpModule"] ?? "ERP"} / {occ["Screen"] ?? "(unknown screen)"} - {occ["Message"]}", 200);

            var ticketId = ExecScalarLong(c, tx, """
                INSERT INTO Ticket (TicketNumber, OccurrenceId, FingerprintId, Status, Severity, Queue,
                  Title, UserDescription, ReportedByUserProfileId, ReportedByUserName, CreatedVia,
                  ErpModule, Environment,
                  CreatedUtc, LastStatusChangeUtc, SlaFirstResponseMinutes, SlaResolutionMinutes,
                  LinkedOccurrenceCount)
                VALUES ($num,$occ,$fp,'new',$sev,$queue,$title,$desc,$byid,$by,$via,$mod,$env,$now,$now,$fr,$res,1);
                SELECT last_insert_rowid();
                """,
                ("$num", ticketNumber), ("$occ", occurrenceId), ("$fp", fingerprintId),
                ("$sev", severity), ("$queue", severity == "critical" ? "application" : "general"),
                ("$title", title), ("$desc", description),
                ("$byid", reportedByProfileId), ("$by", NameOf(reportedByProfileId)), ("$via", createdVia),
                ("$mod", occ["ErpModule"]), ("$env", occ["Environment"]),
                ("$now", Iso(now)), ("$fr", sla.FirstResponse), ("$res", sla.Resolution));

            Exec(c, tx, """
                INSERT INTO TicketHistory (TicketId, SequenceNo, FromStatus, ToStatus,
                  ChangedByUserProfileId, ChangedByUserName, ChangedUtc, MinutesInFromStatus, Comments)
                VALUES ($t, 1, NULL, 'new', $byid, $by, $now, NULL, $c)
                """,
                ("$t", ticketId), ("$byid", reportedByProfileId),
                ("$by", NameOf(reportedByProfileId)), ("$now", Iso(now)),
                ("$c", createdVia == "auto_rule"
                    ? "Ticket raised automatically by an error-management rule."
                    : "Ticket raised by the user from the error dialog."));

            Exec(c, tx, "INSERT OR IGNORE INTO TicketLink (TicketId, OccurrenceId, LinkReason, LinkedUtc) " +
                        "VALUES ($t,$o,'primary',$at)",
                ("$t", ticketId), ("$o", occurrenceId), ("$at", Iso(now)));

            Exec(c, tx, "UPDATE Occurrence SET TicketId = $t WHERE OccurrenceId = $o",
                ("$t", ticketId), ("$o", occurrenceId));

            Exec(c, tx, "UPDATE Fingerprint SET OpenTicketId = $t, " +
                        "TriageState = CASE WHEN TriageState = 'new' THEN 'acknowledged' ELSE TriageState END " +
                        "WHERE FingerprintId = $fp",
                ("$t", ticketId), ("$fp", fingerprintId));

            tx.Commit();

            return new TicketCreateResult
            {
                TicketNumber = ticketNumber, TicketId = ticketId, WasDeduplicated = false
            };
        }
    }

    /* ==================================================================== */
    /*  usp_Ticket_ChangeStatus                                             */
    /* ==================================================================== */

    public object ChangeStatus(string ticketNumber, string toStatus, int changedByProfileId,
        string? comments, int? assignToProfileId)
    {
        lock (_writeLock)
        {
            using var c = Open();
            using var tx = c.BeginTransaction();

            var t = QueryOne(c, tx, """
                SELECT TicketId, Status, CreatedUtc, LastStatusChangeUtc, FirstResponseUtc,
                       AssignedUtc, FingerprintId, ReportedByUserProfileId, ReportedByUserName,
                       AssignedToUserProfileId, AssignedToUserName,
                       SlaFirstResponseMinutes, SlaResolutionMinutes, SlaFirstResponseBreached,
                       SlaResolutionBreached, ReopenCount
                FROM Ticket WHERE TicketNumber = $n
                """, ("$n", ticketNumber));

            if (t is null) throw new InvalidOperationException($"Ticket {ticketNumber} does not exist.");

            var ticketId = Convert.ToInt64(t["TicketId"]);
            var fromStatus = (string)t["Status"]!;

            if (string.Equals(fromStatus, toStatus, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Ticket is already in that status.");

            if (!Statuses.TryGetValue(toStatus, out var to))
                throw new InvalidOperationException($"Unknown status '{toStatus}'.");

            if (!Transitions.TryGetValue((fromStatus.ToLowerInvariant(), toStatus.ToLowerInvariant()),
                    out var requiresComment))
                throw new InvalidOperationException(
                    $"Transition \"{Statuses[fromStatus].Display}\" -> \"{to.Display}\" " +
                    "is not permitted by the configured workflow.");

            if (requiresComment && string.IsNullOrWhiteSpace(comments))
                throw new InvalidOperationException("This status change requires a comment.");

            var now = DateTime.UtcNow;
            var createdUtc = ParseUtc(t["CreatedUtc"] as string) ?? now;
            var lastChange = ParseUtc(t["LastStatusChangeUtc"] as string) ?? createdUtc;
            var minutesInFrom = (int)Math.Round((now - lastChange).TotalMinutes);

            var seq = ExecScalarLong(c, tx,
                "SELECT COALESCE(MAX(SequenceNo),0) + 1 FROM TicketHistory WHERE TicketId = $t",
                ("$t", ticketId));

            Exec(c, tx, """
                INSERT INTO TicketHistory (TicketId, SequenceNo, FromStatus, ToStatus,
                  ChangedByUserProfileId, ChangedByUserName, ChangedUtc, MinutesInFromStatus, Comments)
                VALUES ($t,$seq,$from,$to,$byid,$by,$now,$mins,$c)
                """,
                ("$t", ticketId), ("$seq", seq), ("$from", fromStatus), ("$to", toStatus),
                ("$byid", changedByProfileId), ("$by", NameOf(changedByProfileId)),
                ("$now", Iso(now)), ("$mins", minutesInFrom), ("$c", comments));

            // Paused minutes, banked across every previous pause plus this one.
            var pausedMinutes = 0L;
            foreach (var row in Query(c, tx,
                "SELECT FromStatus, MinutesInFromStatus FROM TicketHistory WHERE TicketId = $t AND MinutesInFromStatus IS NOT NULL",
                ("$t", ticketId)))
            {
                var fs = row["FromStatus"] as string;
                if (fs is not null && Statuses.TryGetValue(fs, out var st) && st.IsPaused)
                    pausedMinutes += Convert.ToInt64(row["MinutesInFromStatus"]);
            }

            var totalElapsed = (int)Math.Round((now - createdUtc).TotalMinutes);
            var activeMinutes = (int)(totalElapsed - pausedMinutes);

            var firstResponseUtc = Val(t, "FirstResponseUtc") as string;
            // First response = the first time someone other than the reporter acts.
            if (firstResponseUtc is null &&
                changedByProfileId != Convert.ToInt32(t["ReportedByUserProfileId"]))
                firstResponseUtc = Iso(now);

            var assignedUtc = t["AssignedUtc"] as string
                ?? (toStatus.Equals("assigned", StringComparison.OrdinalIgnoreCase) ? Iso(now) : null);

            var resolvedUtc = toStatus.Equals("resolved", StringComparison.OrdinalIgnoreCase) ? Iso(now)
                : toStatus.Equals("reopened", StringComparison.OrdinalIgnoreCase) ? null
                : QueryOne(c, tx, "SELECT ResolvedUtc FROM Ticket WHERE TicketId=$t", ("$t", ticketId))?["ResolvedUtc"] as string;

            var closedUtc = to.IsTerminal ? Iso(now)
                : toStatus.Equals("reopened", StringComparison.OrdinalIgnoreCase) ? null
                : QueryOne(c, tx, "SELECT ClosedUtc FROM Ticket WHERE TicketId=$t", ("$t", ticketId))?["ClosedUtc"] as string;

            var slaFr = t["SlaFirstResponseMinutes"] is null ? (int?)null : Convert.ToInt32(t["SlaFirstResponseMinutes"]);
            var slaRes = t["SlaResolutionMinutes"] is null ? (int?)null : Convert.ToInt32(t["SlaResolutionMinutes"]);

            var frBreached = Convert.ToInt64(t["SlaFirstResponseBreached"]) == 1;
            if (!frBreached && slaFr is int frTarget && firstResponseUtc is not null)
                frBreached = (ParseUtc(firstResponseUtc)!.Value - createdUtc).TotalMinutes > frTarget;

            var resBreached = Convert.ToInt64(t["SlaResolutionBreached"]) == 1;
            if (!resBreached && slaRes is int resTarget && resolvedUtc is not null)
                resBreached = activeMinutes > resTarget;

            var reopenCount = Convert.ToInt64(t["ReopenCount"]) +
                              (toStatus.Equals("reopened", StringComparison.OrdinalIgnoreCase) ? 1 : 0);

            Exec(c, tx, """
                UPDATE Ticket SET Status=$to, LastStatusChangeUtc=$now,
                  FirstResponseUtc=$fr, AssignedUtc=$assigned, ResolvedUtc=$resolved, ClosedUtc=$closed,
                  AssignedToUserProfileId=COALESCE($assignToId, AssignedToUserProfileId),
                  AssignedToUserName=COALESCE($assignTo, AssignedToUserName),
                  TotalElapsedMinutes=$total, ActiveProcessingMinutes=$active,
                  SlaFirstResponseBreached=$frb, SlaResolutionBreached=$resb, ReopenCount=$reopen,
                  ResolutionNotes=COALESCE($resolutionNotes, ResolutionNotes)
                WHERE TicketId=$t
                """,
                ("$to", toStatus), ("$now", Iso(now)), ("$fr", firstResponseUtc),
                ("$assigned", assignedUtc), ("$resolved", resolvedUtc), ("$closed", closedUtc),
                ("$assignToId", assignToProfileId is > 0 ? assignToProfileId.Value : (object?)null),
                ("$assignTo", assignToProfileId is > 0 ? NameOf(assignToProfileId.Value) : null),
                ("$total", totalElapsed), ("$active", activeMinutes),
                ("$frb", frBreached ? 1 : 0), ("$resb", resBreached ? 1 : 0),
                ("$reopen", reopenCount),
                // Only on the transition INTO resolved: a note attached to any
                // other transition is working commentary, not a resolution.
                ("$resolutionNotes", toStatus.Equals("resolved", StringComparison.OrdinalIgnoreCase)
                    ? comments : null),
                ("$t", ticketId));

            // Mirrors usp_Ticket_RecordAssigneeOnHistory: stamp the history row
            // with who holds the ticket AFTER the change. Without it a status
            // row answers "who moved it" but not "to whom", and the assignment
            // rows alone cannot reconstruct that - which is exactly the gap this
            // audit trail exists to close.
            Exec(c, tx, """
                UPDATE TicketHistory
                   SET AssignedToUserProfileId = (SELECT AssignedToUserProfileId FROM Ticket WHERE TicketId = $t),
                       AssignedToUserName      = (SELECT AssignedToUserName FROM Ticket WHERE TicketId = $t)
                 WHERE TicketId = $t AND SequenceNo = $seq
                """,
                ("$t", ticketId), ("$seq", seq));

            var fingerprintId = Convert.ToInt64(t["FingerprintId"]);
            if (to.IsTerminal)
                Exec(c, tx, "UPDATE Fingerprint SET OpenTicketId = NULL, " +
                            "TriageState = CASE WHEN TriageState IN ('new','acknowledged') THEN 'resolved' ELSE TriageState END " +
                            "WHERE FingerprintId = $fp AND OpenTicketId = $t",
                    ("$fp", fingerprintId), ("$t", ticketId));
            else if (toStatus.Equals("reopened", StringComparison.OrdinalIgnoreCase))
                Exec(c, tx, "UPDATE Fingerprint SET OpenTicketId = $t, TriageState='acknowledged' WHERE FingerprintId = $fp",
                    ("$fp", fingerprintId), ("$t", ticketId));

            tx.Commit();

            return new
            {
                ticketNumber, fromStatus, toStatus, sequenceNo = seq,
                minutesInPreviousStatus = minutesInFrom,
                totalElapsedMinutes = totalElapsed, activeProcessingMinutes = activeMinutes
            };
        }
    }

    /* ==================================================================== */
    /*  Reads                                                               */
    /* ==================================================================== */

    public object SearchTickets(string? status, bool? onlyOpen)
    {
        using var c = Open();
        var rows = Query(c, null, """
            SELECT t.*, (SELECT COUNT(*) FROM TicketLink l WHERE l.TicketId = t.TicketId) AS LinkedCount,
                   o.ErrorReference
            FROM Ticket t LEFT JOIN Occurrence o ON o.OccurrenceId = t.OccurrenceId
            ORDER BY t.CreatedUtc DESC
            """);

        var items = rows
            .Where(r => status is null || string.Equals(r["Status"] as string, status, StringComparison.OrdinalIgnoreCase))
            .Where(r => onlyOpen != true || Statuses[(string)r["Status"]!].IsOpen)
            .Select(r =>
            {
                var st = Statuses[(string)r["Status"]!];
                var created = ParseUtc(r["CreatedUtc"] as string) ?? DateTime.UtcNow;
                var lastChange = ParseUtc(r["LastStatusChangeUtc"] as string) ?? created;
                // For an open ticket the stored elapsed value is stale by
                // definition - recompute live, exactly as usp_Ticket_Search does.
                var elapsed = st.IsTerminal
                    ? Convert.ToInt32(r["TotalElapsedMinutes"] ?? 0)
                    : (int)Math.Round((DateTime.UtcNow - created).TotalMinutes);

                return new
                {
                    ticketNumber = r["TicketNumber"],
                    title = r["Title"],
                    statusCode = r["Status"],
                    statusName = st.Display,
                    isOpen = st.IsOpen,
                    isTerminal = st.IsTerminal,
                    severityCode = r["Severity"],
                    queue = r["Queue"],
                    createdVia = r["CreatedVia"],
                    ticketSource = Val(r, "TicketSource"),
                    reportedBy = r["ReportedByUserName"],
                    assignedTo = r["AssignedToUserName"],
                    erpModule = r["ErpModule"],
                    createdUtc = r["CreatedUtc"],
                    firstResponseUtc = r["FirstResponseUtc"],
                    resolvedUtc = r["ResolvedUtc"],
                    closedUtc = r["ClosedUtc"],
                    totalElapsedMinutes = elapsed,
                    activeProcessingMinutes = r["ActiveProcessingMinutes"] is null ? (int?)null : Convert.ToInt32(r["ActiveProcessingMinutes"]),
                    slaFirstResponseTargetMinutes = r["SlaFirstResponseMinutes"],
                    slaResolutionTargetMinutes = r["SlaResolutionMinutes"],
                    slaFirstResponseBreached = Convert.ToInt64(r["SlaFirstResponseBreached"]) == 1,
                    slaResolutionBreached = Convert.ToInt64(r["SlaResolutionBreached"]) == 1,
                    reopenCount = r["ReopenCount"],
                    linkedOccurrenceCount = r["LinkedCount"],
                    primaryErrorReference = r["ErrorReference"],
                    allowedTransitions = Transitions.Keys
                        .Where(k => k.Item1 == ((string)r["Status"]!).ToLowerInvariant())
                        .Select(k => new { to = k.Item2, display = Statuses[k.Item2].Display,
                                           requiresComment = Transitions[k] })
                        .ToList()
                };
            }).ToList();

        return new { items, total = items.Count };
    }

    public object? GetTicket(string ticketNumber)
    {
        using var c = Open();
        var t = QueryOne(c, null, """
            SELECT t.*, o.ErrorReference FROM Ticket t
            LEFT JOIN Occurrence o ON o.OccurrenceId = t.OccurrenceId
            WHERE t.TicketNumber = $n
            """, ("$n", ticketNumber));
        if (t is null) return null;

        var ticketId = Convert.ToInt64(t["TicketId"]);

        var history = Query(c, null,
            "SELECT * FROM TicketHistory WHERE TicketId = $t ORDER BY SequenceNo", ("$t", ticketId))
            .Select(h => new
            {
                sequenceNo = h["SequenceNo"],
                fromStatus = h["FromStatus"],
                fromStatusName = h["FromStatus"] is null ? null : Statuses[(string)h["FromStatus"]!].Display,
                toStatus = h["ToStatus"],
                toStatusName = Statuses[(string)h["ToStatus"]!].Display,
                changedBy = h["ChangedByUserName"],
                changedUtc = h["ChangedUtc"],
                minutesInFromStatus = h["MinutesInFromStatus"],
                comments = h["Comments"],
                // Surfaced so the assignment audit is VISIBLE, not merely
                // stored. An audit trail nobody can read is not an audit trail.
                changeKind = Val(h, "ChangeKind"),
                assignedTo = Val(h, "AssignedToUserName"),
                previousAssignedTo = Val(h, "PreviousAssignedToUserName")
            }).ToList();

        // "Time spent in each status" - derived from the audit rows, which is
        // why MinutesInFromStatus is written as it happens rather than
        // reconstructed at report time.
        var timeInStatus = Query(c, null,
            "SELECT FromStatus, SUM(MinutesInFromStatus) AS Mins, COUNT(*) AS Times " +
            "FROM TicketHistory WHERE TicketId = $t AND MinutesInFromStatus IS NOT NULL GROUP BY FromStatus",
            ("$t", ticketId))
            .Where(r => r["FromStatus"] is not null)
            .Select(r => new
            {
                statusCode = r["FromStatus"],
                statusName = Statuses[(string)r["FromStatus"]!].Display,
                minutesInStatus = r["Mins"],
                timesEntered = r["Times"],
                countsTowardActiveTime = !Statuses[(string)r["FromStatus"]!].IsPaused
            }).ToList();

        var linked = Query(c, null, """
            SELECT o.ErrorReference, o.OccurredUtc, o.UserName, o.Screen, o.Component, o.Message, l.LinkReason
            FROM TicketLink l JOIN Occurrence o ON o.OccurrenceId = l.OccurrenceId
            WHERE l.TicketId = $t ORDER BY o.OccurredUtc DESC LIMIT 200
            """, ("$t", ticketId))
            .Select(r => new
            {
                errorReference = r["ErrorReference"], occurredUtc = r["OccurredUtc"],
                userName = r["UserName"], screen = r["Screen"], component = r["Component"],
                message = r["Message"], linkReason = r["LinkReason"]
            }).ToList();

        var st = Statuses[(string)t["Status"]!];

        var created = ParseUtc(t["CreatedUtc"] as string) ?? DateTime.UtcNow;
        var lastChange = ParseUtc(t["LastStatusChangeUtc"] as string) ?? created;
        var pausedMinutes = timeInStatus.Where(x => !x.countsTowardActiveTime)
                                        .Sum(x => Convert.ToInt64(x.minutesInStatus));
        var liveElapsed = st.IsTerminal && t["TotalElapsedMinutes"] is not null
            ? Convert.ToInt32(t["TotalElapsedMinutes"])
            : (int)Math.Round((DateTime.UtcNow - created).TotalMinutes);
        var liveActive = st.IsTerminal && t["ActiveProcessingMinutes"] is not null
            ? Convert.ToInt32(t["ActiveProcessingMinutes"])
            : (int)(liveElapsed - pausedMinutes
                    - (st.IsPaused ? (long)Math.Round((DateTime.UtcNow - lastChange).TotalMinutes) : 0));

        return new
        {
            ticketNumber = t["TicketNumber"], title = t["Title"],
            userDescription = Val(t, "UserDescription"),
            statusCode = t["Status"], statusName = st.Display, isOpen = st.IsOpen,
            severityCode = t["Severity"], queue = t["Queue"], createdVia = t["CreatedVia"],
            reportedBy = t["ReportedByUserName"],
            assignedTo = t["AssignedToUserName"],
            assignedToProfileId = Val(t, "AssignedToUserProfileId"),
            // 'error' or 'manual'. Without this the console cannot tell a
            // captured fault from a request somebody typed, and the badge
            // showed "captured error" for everything.
            ticketSource = Val(t, "TicketSource"),
            requestCategory = Val(t, "RequestCategory"),
            reportedScreen = Val(t, "ReportedScreen"),
            erpModule = Val(t, "ErpModule"), environment = t["Environment"],
            createdUtc = t["CreatedUtc"],
            firstResponseUtc = Val(t, "FirstResponseUtc"),
            resolvedUtc = Val(t, "ResolvedUtc"),
            closedUtc = Val(t, "ClosedUtc"),
            // Live for an open ticket - the stored value was last written at
            // the previous status change, so a freshly created ticket would
            // report null and the console would show an empty cell.
            totalElapsedMinutes = liveElapsed,
            activeProcessingMinutes = liveActive,
            slaFirstResponseBreached = Convert.ToInt64(t["SlaFirstResponseBreached"]) == 1,
            slaResolutionBreached = Convert.ToInt64(t["SlaResolutionBreached"]) == 1,
            linkedOccurrenceCount = t["LinkedOccurrenceCount"],
            primaryErrorReference = Val(t, "ErrorReference"),
            history, timeInStatus, linkedOccurrences = linked,
            allowedTransitions = Transitions.Keys
                .Where(k => k.Item1 == ((string)t["Status"]!).ToLowerInvariant())
                .Select(k => new { to = k.Item2, display = Statuses[k.Item2].Display,
                                   requiresComment = Transitions[k] }).ToList()
        };
    }

    /// <summary>
    /// Mirrors usp_Error_Search: filtering, sorting and paging all happen in
    /// SQL, and only one page ever leaves the database.
    ///
    /// The previous version took the newest 300 rows and then filtered them in
    /// memory with LINQ. That is wrong in a way worth naming: filtering by
    /// severity AFTER capping means "show me critical errors" searched only the
    /// most recent 300 rows, so a critical error from an hour ago simply was
    /// not there. It looked fine on demo data and would have been a support
    /// console that quietly lies.
    /// </summary>
    public object SearchErrors(ErrorQuery q)
    {
        using var c = Open();

        // Whitelisted sort, exactly like ERM.ERM_SortWhitelist - the caller's
        // value is a lookup key, never concatenated SQL.
        // Resolve to the EFFECTIVE key, and report that back rather than
        // echoing what was asked for. Echoing an unrecognised key told the UI
        // its sort had been applied when it had silently fallen back - the
        // arrows then pointed at a column the rows were not ordered by.
        var effectiveSort = ErrorSorts.ContainsKey(q.SortBy ?? "") ? q.SortBy! : "occurred_desc";
        var orderBy = ErrorSorts[effectiveSort];

        var where = new List<string> { "1=1" };
        var ps = new List<(string, object?)>();

        void Filter(string sql, string name, object? value)
        {
            if (value is null || (value is string sv && string.IsNullOrWhiteSpace(sv))) return;
            where.Add(sql);
            ps.Add((name, value));
        }

        Filter("o.Severity = $sev", "$sev", q.Severity);
        Filter("o.Layer = $layer", "$layer", q.Layer);
        Filter("o.Category = $cat", "$cat", q.Category);
        Filter("o.ErpModule = $mod", "$mod", q.ErpModule);
        Filter("o.UserName = $user", "$user", q.UserName);
        Filter("o.ErrorReference = $ref", "$ref", q.ErrorReference);
        Filter("o.CorrelationId = $corr", "$corr", q.CorrelationId);
        Filter("f.FingerprintId = $fp", "$fp", q.FingerprintId);
        Filter("o.OccurredUtc >= $from", "$from", q.FromUtc);
        Filter("o.OccurredUtc <= $to", "$to", q.ToUtc);

        if (q.OnlyUnticketed == true) where.Add("o.TicketId IS NULL");

        if (!string.IsNullOrWhiteSpace(q.SearchText))
        {
            where.Add("(o.Message LIKE $q OR o.ExceptionType LIKE $q OR o.Screen LIKE $q)");
            ps.Add(("$q", "%" + q.SearchText + "%"));
        }

        var predicate = string.Join(" AND ", where);
        var pageSize = Math.Clamp(q.PageSize <= 0 ? 50 : q.PageSize, 1, 500);
        var page = Math.Max(1, q.PageNumber);

        // The total is a separate COUNT so the page query stays a plain
        // indexed read. In production this is COUNT(*) OVER () in the same
        // statement, and it is optional for exactly this reason - it is the
        // expensive half on a large filtered set.
        var total = ExecScalarLong(c, null, $"""
            SELECT COUNT(*) FROM Occurrence o
            JOIN Fingerprint f ON f.FingerprintId = o.FingerprintId
            WHERE {predicate}
            """, ps.ToArray());

        var rows = Query(c, null, $"""
            SELECT o.*, f.FingerprintHash, f.OccurrenceCount, f.DistinctUserCount,
                   f.FirstSeenUtc, f.LastSeenUtc, f.TriageState, f.SignatureText,
                   t.TicketNumber, t.Status AS TicketStatus
            FROM Occurrence o
            JOIN Fingerprint f ON f.FingerprintId = o.FingerprintId
            LEFT JOIN Ticket t ON t.TicketId = o.TicketId
            WHERE {predicate}
            ORDER BY {orderBy}
            LIMIT $take OFFSET $skip
            """, ps.Concat(new (string, object?)[]
            {
                ("$take", pageSize), ("$skip", (page - 1) * pageSize)
            }).ToArray());

        var items = rows.Select(r => new
        {
            errorReference = r["ErrorReference"], occurredUtc = r["OccurredUtc"],
            layer = r["Layer"], category = r["Category"], severity = r["Severity"],
            exceptionType = r["ExceptionType"], message = r["Message"],
            erpModule = r["ErpModule"], screen = r["Screen"], component = r["Component"],
            apiController = r["ApiController"], apiAction = r["ApiAction"],
            apiEndpoint = r["ApiEndpoint"], httpStatusCode = r["HttpStatusCode"],
            sqlErrorNumber = r["SqlErrorNumber"], sqlObjectName = r["SqlObjectName"],
            sqlLineNumber = r["SqlLineNumber"], sqlDatabaseName = r["SqlDatabaseName"],
            userName = r["UserName"], correlationId = r["CorrelationId"],
            environment = r["Environment"], browserName = r["BrowserName"],
            fingerprintHash = ((string?)r["FingerprintHash"])?[..12],
            fingerprintOccurrenceCount = r["OccurrenceCount"],
            distinctUserCount = r["DistinctUserCount"],
            triageState = r["TriageState"],
            ticketNumber = r["TicketNumber"]
        }).ToList();

        return new
        {
            items,
            total,
            pageNumber = page,
            pageSize,
            totalPages = (int)Math.Ceiling(total / (double)pageSize),
            sortBy = effectiveSort
        };
    }

    /// <summary>Whitelisted sorts. Every one ends in a unique tiebreaker.</summary>
    private static readonly Dictionary<string, string> ErrorSorts = new(StringComparer.OrdinalIgnoreCase)
    {
        ["occurred_desc"] = "o.OccurredUtc DESC, o.OccurrenceId DESC",
        ["occurred_asc"]  = "o.OccurredUtc ASC, o.OccurrenceId ASC",
        // Severity sorts by RANK, not alphabetically - 'critical' < 'high' is
        // true as text but meaningless as severity.
        ["severity"]      = "CASE o.Severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1 "
                          + "WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END ASC, "
                          + "o.OccurredUtc DESC, o.OccurrenceId DESC",
        ["module"]        = "o.ErpModule ASC, o.OccurredUtc DESC, o.OccurrenceId DESC",
        ["screen"]        = "o.Screen ASC, o.OccurredUtc DESC, o.OccurrenceId DESC",
        ["user"]          = "o.UserName ASC, o.OccurredUtc DESC, o.OccurrenceId DESC",
        ["frequency"]     = "f.OccurrenceCount DESC, o.OccurredUtc DESC, o.OccurrenceId DESC",
        ["layer"]         = "o.Layer ASC, o.OccurredUtc DESC, o.OccurrenceId DESC",
    };

    public object GetErrorDetail(string errorReference)
    {
        using var c = Open();
        var r = QueryOne(c, null, """
            SELECT o.*, f.FingerprintHash, f.SignatureText, f.OccurrenceCount, f.DistinctUserCount,
                   f.FirstSeenUtc, f.LastSeenUtc, f.TriageState, t.TicketNumber
            FROM Occurrence o JOIN Fingerprint f ON f.FingerprintId = o.FingerprintId
            LEFT JOIN Ticket t ON t.TicketId = o.TicketId
            WHERE o.ErrorReference = $r
            """, ("$r", errorReference));
        if (r is null) return new { };

        return new
        {
            errorReference = r["ErrorReference"], occurredUtc = r["OccurredUtc"],
            layer = r["Layer"], category = r["Category"], severity = r["Severity"],
            exceptionType = r["ExceptionType"], message = r["Message"],
            erpModule = r["ErpModule"], screen = r["Screen"], component = r["Component"],
            routeUrl = r["RouteUrl"], actionName = r["ActionName"],
            formName = r["FormName"], lovName = r["LovName"],
            apiController = r["ApiController"], apiAction = r["ApiAction"],
            apiEndpoint = r["ApiEndpoint"], httpStatusCode = r["HttpStatusCode"],
            sql = new
            {
                number = r["SqlErrorNumber"], objectName = r["SqlObjectName"],
                lineNumber = r["SqlLineNumber"], serverName = r["SqlServerName"],
                databaseName = r["SqlDatabaseName"], schemaName = r["SqlSchemaName"]
            },
            userName = r["UserName"], correlationId = r["CorrelationId"],
            environment = r["Environment"], appVersion = r["AppVersion"],
            browserName = r["BrowserName"], browserVersion = r["BrowserVersion"], osName = r["OsName"],
            stackTrace = r["StackTrace"], innerExceptionChain = r["InnerExceptionChain"],
            requestPayload = Parse(r["RequestPayloadJson"] as string),
            validationErrors = Parse(r["ValidationErrorsJson"] as string),
            breadcrumbs = Parse(r["BreadcrumbsJson"] as string),
            fingerprintHash = r["FingerprintHash"], signatureText = r["SignatureText"],
            occurrenceCount = r["OccurrenceCount"], distinctUserCount = r["DistinctUserCount"],
            firstSeenUtc = r["FirstSeenUtc"], lastSeenUtc = r["LastSeenUtc"],
            triageState = r["TriageState"],
            ticketNumber = r["TicketNumber"]
        };
    }

    /// <summary>
    /// Mirrors the rewritten usp_Error_RecurringProblems: the occurrence table
    /// is aggregated ONCE over the window, then joined - not counted per
    /// fingerprint row.
    /// </summary>
    public object RecurringProblems(ProblemQuery q)
    {
        using var c = Open();

        var effectiveSort = ProblemSorts.ContainsKey(q.SortBy ?? "") ? q.SortBy! : "window_count";
        var orderBy = ProblemSorts[effectiveSort];

        var from = q.FromUtc ?? Iso(DateTime.UtcNow.AddDays(-30));
        var minOcc = q.MinOccurrences <= 0 ? 1 : q.MinOccurrences;
        var pageSize = Math.Clamp(q.PageSize <= 0 ? 50 : q.PageSize, 1, 500);
        var page = Math.Max(1, q.PageNumber);

        var where = new List<string> { "1=1" };
        var ps = new List<(string, object?)> { ("$from", from), ("$minOcc", minOcc) };

        if (!string.IsNullOrWhiteSpace(q.Severity)) { where.Add("f.Severity = $sev"); ps.Add(("$sev", q.Severity)); }
        if (!string.IsNullOrWhiteSpace(q.Layer))    { where.Add("f.Layer = $layer"); ps.Add(("$layer", q.Layer)); }
        if (!string.IsNullOrWhiteSpace(q.ErpModule)){ where.Add("f.ErpModule = $mod"); ps.Add(("$mod", q.ErpModule)); }
        if (q.IncludeMuted != true) where.Add("f.TriageState <> 'muted'");

        var predicate = string.Join(" AND ", where);

        // One grouped pass over the window, with the threshold applied during
        // aggregation via HAVING.
        const string winCte = """
            WITH win AS (
              SELECT FingerprintId,
                     COUNT(*) AS WindowOccurrences,
                     COUNT(DISTINCT UserName) AS WindowDistinctUsers,
                     MAX(OccurredUtc) AS WindowLastSeenUtc
              FROM Occurrence
              WHERE OccurredUtc >= $from
              GROUP BY FingerprintId
              HAVING COUNT(*) >= $minOcc
            )
            """;

        var total = ExecScalarLong(c, null, $"""
            {winCte}
            SELECT COUNT(*) FROM win w
            JOIN Fingerprint f ON f.FingerprintId = w.FingerprintId
            WHERE {predicate}
            """, ps.ToArray());

        var rows = Query(c, null, $"""
            {winCte}
            SELECT f.*, w.WindowOccurrences, w.WindowDistinctUsers, w.WindowLastSeenUtc,
                   t.TicketNumber AS OpenTicketNumber
            FROM win w
            JOIN Fingerprint f ON f.FingerprintId = w.FingerprintId
            LEFT JOIN Ticket t ON t.TicketId = f.OpenTicketId
            WHERE {predicate}
            ORDER BY {orderBy}
            LIMIT $take OFFSET $skip
            """, ps.Concat(new (string, object?)[]
            {
                ("$take", pageSize), ("$skip", (page - 1) * pageSize)
            }).ToArray());

        var items = rows.Select(r => new
        {
            fingerprintHash = ((string)r["FingerprintHash"]!)[..12],
            signatureText = r["SignatureText"],
            layer = r["Layer"], category = r["Category"], severity = r["Severity"],
            exceptionType = r["ExceptionType"], normalizedMessage = r["NormalizedMessage"],
            erpModule = r["ErpModule"], screen = r["Screen"], component = r["Component"],
            sqlObjectName = r["SqlObjectName"], apiEndpoint = r["ApiEndpoint"],
            firstSeenUtc = r["FirstSeenUtc"], lastSeenUtc = r["LastSeenUtc"],
            lifetimeOccurrences = r["OccurrenceCount"],
            distinctUserCount = r["DistinctUserCount"],
            windowOccurrences = r["WindowOccurrences"],
            windowDistinctUsers = r["WindowDistinctUsers"],
            triageState = r["TriageState"],
            openTicketNumber = r["OpenTicketNumber"],
            // Kept for the existing template binding.
            occurrenceCount = r["WindowOccurrences"]
        }).ToList();

        return new
        {
            items, total, pageNumber = page, pageSize,
            totalPages = (int)Math.Ceiling(total / (double)pageSize),
            sortBy = effectiveSort
        };
    }

    private static readonly Dictionary<string, string> ProblemSorts = new(StringComparer.OrdinalIgnoreCase)
    {
        ["window_count"]   = "w.WindowOccurrences DESC, f.FingerprintId DESC",
        ["lifetime_count"] = "f.OccurrenceCount DESC, f.FingerprintId DESC",
        ["users"]          = "w.WindowDistinctUsers DESC, f.FingerprintId DESC",
        ["severity"]       = "CASE f.Severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1 "
                           + "WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END ASC, "
                           + "w.WindowOccurrences DESC, f.FingerprintId DESC",
        ["last_seen"]      = "f.LastSeenUtc DESC, f.FingerprintId DESC",
        ["first_seen"]     = "f.FirstSeenUtc ASC, f.FingerprintId ASC",
        ["module"]         = "f.ErpModule ASC, w.WindowOccurrences DESC, f.FingerprintId DESC",
    };

    public object Dashboard()
    {
        using var c = Open();
        var errors = ExecScalarLong(c, null, "SELECT COUNT(*) FROM Occurrence");
        var problems = ExecScalarLong(c, null, "SELECT COUNT(*) FROM Fingerprint");
        var tickets = ExecScalarLong(c, null, "SELECT COUNT(*) FROM Ticket");
        var openTickets = Query(c, null, "SELECT Status FROM Ticket")
            .Count(r => Statuses[(string)r["Status"]!].IsOpen);

        var byLayer = Query(c, null,
            "SELECT Layer, COUNT(*) AS n FROM Occurrence GROUP BY Layer ORDER BY n DESC")
            .Select(r => new { layer = r["Layer"], count = r["n"] }).ToList();

        var bySeverity = Query(c, null,
            "SELECT Severity, COUNT(*) AS n FROM Occurrence GROUP BY Severity")
            .Select(r => new { severity = r["Severity"], count = r["n"] })
            .OrderBy(x => Rank((string)x.severity!)).ToList();

        var topModules = Query(c, null,
            "SELECT COALESCE(ErpModule,'(unknown)') AS m, COUNT(*) AS n FROM Occurrence GROUP BY m ORDER BY n DESC LIMIT 5")
            .Select(r => new { erpModule = r["m"], count = r["n"] }).ToList();

        return new
        {
            errorsCaptured = errors,
            distinctProblems = problems,
            deduplicationRatio = problems == 0 ? 0 : Math.Round((double)errors / problems, 1),
            ticketsCreated = tickets,
            openTickets,
            byLayer, bySeverity, topModules
        };
    }

    public object CorrelationTrail(string correlationId)
    {
        using var c = Open();
        // Deepest layer first: the cause, then the symptom.
        var order = new Dictionary<string, int>
        {
            ["database"] = 0, ["data"] = 1, ["business"] = 2,
            ["webapi"] = 3, ["http"] = 4, ["angular"] = 5
        };

        var items = Query(c, null,
            "SELECT * FROM Occurrence WHERE CorrelationId = $c ORDER BY OccurredUtc",
            ("$c", correlationId))
            .Select(r => new
            {
                errorReference = r["ErrorReference"], occurredUtc = r["OccurredUtc"],
                layer = r["Layer"], category = r["Category"], severity = r["Severity"],
                exceptionType = r["ExceptionType"], message = r["Message"],
                component = r["Component"], screen = r["Screen"],
                apiController = r["ApiController"], apiAction = r["ApiAction"],
                httpStatusCode = r["HttpStatusCode"],
                sqlErrorNumber = r["SqlErrorNumber"], sqlObjectName = r["SqlObjectName"],
                sqlLineNumber = r["SqlLineNumber"]
            })
            .OrderBy(x => order.TryGetValue((string)x.layer! ?? "", out var o) ? o : 9)
            .ToList();

        return new { correlationId, items, total = items.Count };
    }

    /* ==================================================================== */
    /*  End-user ticket access - mirrors db/007                             */
    /*                                                                      */
    /*  Ownership is enforced HERE, in the store, exactly as the T-SQL       */
    /*  enforces it in the procedure - never in the API route and never in   */
    /*  the template. A "not yours" ticket is indistinguishable from a       */
    /*  missing one, so sequential ticket numbers cannot be enumerated.      */
    /* ==================================================================== */

    public object ListTicketsForUser(int userProfileId, bool onlyOpen)
    {
        if (userProfileId <= 0) return new { items = Array.Empty<object>(), total = 0 };

        using var c = Open();
        var rows = Query(c, null, """
            SELECT * FROM Ticket
            WHERE ReportedByUserProfileId = $u
            ORDER BY CreatedUtc DESC
            """, ("$u", userProfileId));

        var items = rows
            .Where(r => !onlyOpen || Statuses[(string)r["Status"]!].IsOpen)
            .Select(r =>
            {
                var st = Statuses[(string)r["Status"]!];
                return new
                {
                    ticketNumber = r["TicketNumber"],
                    title = r["Title"],
                    statusCode = r["Status"],
                    statusName = st.Display,
                    isOpen = st.IsOpen,
                    severityName = r["Severity"],
                    createdUtc = r["CreatedUtc"],
                    resolvedUtc = r["ResolvedUtc"],
                    closedUtc = r["ClosedUtc"],
                    erpModule = r["ErpModule"],
                    latestUpdate = LatestVisibleUpdate(c, Convert.ToInt64(r["TicketId"])),
                    awaitingYourReply = st.IsPaused
                };
            })
            // Anything waiting on the user first: it is the only row they can
            // act on.
            .OrderByDescending(x => x.awaitingYourReply)
            .ToList();

        return new { items, total = items.Count };
    }

    private string? LatestVisibleUpdate(SqliteConnection c, long ticketId)
    {
        var rows = Query(c, null, """
            SELECT Note, At FROM (
              SELECT Comments AS Note, ChangedUtc AS At FROM TicketHistory
                WHERE TicketId = $t AND Comments IS NOT NULL AND IsCustomerVisible = 1
              UNION ALL
              SELECT CommentText, CreatedUtc FROM TicketComment
                WHERE TicketId = $t AND AuthorRole <> 'reporter' AND IsCustomerVisible = 1
            ) ORDER BY At DESC LIMIT 1
            """, ("$t", ticketId));
        return rows.Count == 0 ? null : rows[0]["Note"] as string;
    }

    public object? GetTicketForUser(string ticketNumber, int userProfileId)
    {
        if (userProfileId <= 0) return null;

        using var c = Open();
        var t = QueryOne(c, null, """
            SELECT t.*, o.ErrorReference FROM Ticket t
            LEFT JOIN Occurrence o ON o.OccurrenceId = t.OccurrenceId
            WHERE t.TicketNumber = $n
            """, ("$n", ticketNumber));

        // Not found and not yours return the same thing.
        if (t is null) return null;
        // On the id, not on a case-insensitive name match. A display name is
        // not unique and is editable, so matching on it is a second and weaker
        // door into somebody else's ticket.
        if (Convert.ToInt32(t["ReportedByUserProfileId"]) != userProfileId) return null;

        var ticketId = Convert.ToInt64(t["TicketId"]);
        var st = Statuses[(string)t["Status"]!];

        // IsCustomerVisible = 1, exactly as usp_Ticket_GetForUser does it.
        // Omitting the changed-by NAME is not enough on its own: the assignment
        // row's own comment reads "Assigned to Ana Silva", so without this
        // filter the end user is told which engineer holds their ticket - which
        // invites them to chase that person directly, and is the reason the
        // assignment row is written with IsCustomerVisible = 0 at all.
        var history = Query(c, null,
            "SELECT * FROM TicketHistory WHERE TicketId = $t AND IsCustomerVisible = 1 ORDER BY SequenceNo",
            ("$t", ticketId))
            .Select(h => new
            {
                sequenceNo = h["SequenceNo"],
                statusName = Statuses[(string)h["ToStatus"]!].Display,
                changedUtc = h["ChangedUtc"],
                comments = h["Comments"]
                // ChangedByUserName deliberately omitted: which engineer
                // touched the ticket is internal.
            }).ToList();

        // Same rule for comments: an internal note is internal.
        var comments = Query(c, null,
            "SELECT * FROM TicketComment WHERE TicketId = $t AND IsCustomerVisible = 1 ORDER BY CreatedUtc",
            ("$t", ticketId))
            .Select(cm => new
            {
                authorRole = cm["AuthorRole"],
                // Support is shown as a team, not as a named individual.
                authorName = (cm["AuthorRole"] as string) == "reporter"
                    ? cm["AuthorUserName"] : "Support",
                commentText = cm["CommentText"],
                createdUtc = cm["CreatedUtc"]
            }).ToList();

        return new
        {
            ticketNumber = t["TicketNumber"],
            title = t["Title"],
            statusCode = t["Status"],
            statusName = st.Display,
            isOpen = st.IsOpen,
            severityName = t["Severity"],
            erpModule = Val(t, "ErpModule"),
            createdUtc = t["CreatedUtc"],
            firstResponseUtc = Val(t, "FirstResponseUtc"),
            resolvedUtc = Val(t, "ResolvedUtc"),
            closedUtc = Val(t, "ClosedUtc"),
            errorReference = Val(t, "ErrorReference"),
            yourDescription = Val(t, "UserDescription"),
            // Withheld while still open: a half-written resolution note read as
            // a promise is worse than no note.
            resolutionNotes = (st.IsTerminal || Val(t, "ResolvedUtc") is not null)
                ? Val(t, "ResolutionNotes") : null,
            awaitingYourReply = st.IsPaused,
            canComment = !st.IsTerminal,
            history,
            comments
        };
    }

    public bool AddUserComment(string ticketNumber, int userProfileId, string commentText)
    {
        if (userProfileId <= 0 || string.IsNullOrWhiteSpace(commentText)) return false;

        lock (_writeLock)
        {
            using var c = Open();

            var t = QueryOne(c, null,
                "SELECT TicketId, Status, ReportedByUserProfileId FROM Ticket WHERE TicketNumber = $n",
                ("$n", ticketNumber));
            if (t is null) return false;
            if (Convert.ToInt32(t["ReportedByUserProfileId"]) != userProfileId) return false;

            var status = (string)t["Status"]!;
            if (Statuses[status].IsTerminal) return false;

            var ticketId = Convert.ToInt64(t["TicketId"]);

            Exec(c, null, """
                INSERT INTO TicketComment (TicketId, AuthorUserProfileId, AuthorUserName, AuthorRole,
                                           CommentText, IsCustomerVisible, CreatedUtc)
                VALUES ($t, $uid, $u, 'reporter', $c, 1, $at)
                """,
                ("$t", ticketId), ("$uid", userProfileId), ("$u", NameOf(userProfileId)),
                // Scrubbed: the user is typing into a field support will read
                // and that may be exported. They will paste a token eventually.
                ("$c", Redactor.ScrubText(commentText, 4000)), ("$at", Iso(DateTime.UtcNow)));

            // A reply un-blocks support. Routed through the normal status
            // change so the transition is validated and the audit row and
            // paused-minutes accounting are written exactly as usual.
            if (Statuses[status].IsPaused
                && Transitions.ContainsKey((status.ToLowerInvariant(), "in_progress")))
            {
                try
                {
                    ChangeStatus(ticketNumber, "in_progress", userProfileId,
                        "Reporter replied with the requested information.", null);
                }
                catch (InvalidOperationException)
                {
                    // The workflow is the authority. If it forbids the move, the
                    // comment still stands - it is not worth losing the reply.
                }
            }

            return true;
        }
    }

    /* ==================================================================== */
    /*  Server-side envelope construction, for the failing demo endpoints   */
    /* ==================================================================== */

    public ErrorEnvelope BuildServerEnvelope(HttpContext ctx, string layer, string category,
        string severity, string exceptionType, string message, string stack,
        string? controller = null, string? action = null, SqlErrorInfo? sql = null)
    {
        var correlationId = ctx.Request.Headers["X-Correlation-Id"].FirstOrDefault()
                            ?? Guid.NewGuid().ToString();
        var module = ctx.Request.Headers["X-Erp-Module"].FirstOrDefault();
        var screen = ctx.Request.Headers["X-Erp-Screen"].FirstOrDefault();

        // Uses the SAME Fingerprint.Compute the production packages use.
        var fp = Fingerprint.Compute(new Fingerprint.Input
        {
            Layer = layer, Category = category, ExceptionType = exceptionType,
            Message = message, StackTrace = stack,
            ApiController = controller, ApiAction = action,
            ErpModule = module, Screen = screen,
            SqlErrorNumber = sql?.Number, SqlObjectName = sql?.ObjectName
        });

        return new ErrorEnvelope
        {
            FingerprintHash = fp.Hash, SignatureText = fp.Signature,
            Layer = layer, Category = category, Severity = severity,
            ExceptionType = exceptionType,
            Message = Redactor.ScrubText(message, 2000),
            NormalizedMessage = fp.NormalizedMessage,
            OccurredUtc = DateTime.UtcNow.ToString("o"),
            ErpModule = module, Screen = screen,
            ApiApplication = "ERP.Api", ApiController = controller, ApiAction = action,
            ApiEndpoint = ctx.Request.Path.Value, HttpMethod = ctx.Request.Method,
            Sql = sql,
            User = new UserContext { ProfileId = ProfileIdOf("fatima.saeed"), Name = "fatima.saeed", DisplayName = "Fatima Saeed" },
            CorrelationId = correlationId,
            RequestId = ctx.Request.Headers["X-Request-Id"].FirstOrDefault(),
            Environment = "Demo", AppVersion = "2026.3.1",
            StackTrace = Redactor.ScrubText(stack, 20000)
        };
    }

    /// <summary>Pre-populate a plausible history so the admin views are not empty.</summary>
    public void Seed()
    {
        lock (_writeLock)
        {
            using var rc = Open();
            // The support roster. fatima.saeed is DELIBERATELY absent - she is
            // an ordinary ERP user, and the demo uses her to show the admin API
            // refusing a normal user rather than just asserting that it would.
            foreach (var (u, d, r) in new[]
            {
                ("sam.ops",    "Sam Ortega",  "support_lead"),
                ("dev.patel",  "Dev Patel",   "developer"),
                ("ana.silva",  "Ana Silva",   "support_agent"),
                ("mgr.khoury", "Maya Khoury", "support_viewer"),
            })
            {
                Exec(rc, null,
                    "INSERT OR IGNORE INTO SupportUser (UserProfileId, UserName, DisplayName, RoleCode) "
                    + "VALUES ($id,$u,$d,$r)",
                    ("$id", ProfileIdOf(u)), ("$u", u), ("$d", d), ("$r", r));
            }
        }

        var users = new[] { "fatima.saeed", "omar.khan", "lisa.chen", "raj.patel" };
        var rnd = new Random(20260915);

        // One recurring LOV fault across four users - the case the
        // recurring-problems report exists to surface.
        for (var i = 0; i < 14; i++)
        {
            var fp = Fingerprint.Compute(new Fingerprint.Input
            {
                Layer = ErrorLayers.Database, Category = ErrorCategories.SqlProcedure,
                ExceptionType = "System.Data.SqlClient.SqlException",
                Message = $"Invalid column name 'IsActiveFlag'. (request {Guid.NewGuid()})",
                StackTrace = "   at Erp.Common.LovRepository.Load(String lovCode) in C:\\build\\src\\LovRepository.cs:line 41",
                SqlErrorNumber = 207, SqlObjectName = "usp_GetCostCentreLov"
            });

            Capture(new ErrorEnvelope
            {
                FingerprintHash = fp.Hash, SignatureText = fp.Signature,
                Layer = ErrorLayers.Database, Category = ErrorCategories.SqlProcedure,
                Severity = "medium",
                ExceptionType = "System.Data.SqlClient.SqlException",
                Message = "Invalid column name 'IsActiveFlag'.",
                NormalizedMessage = fp.NormalizedMessage,
                OccurredUtc = DateTime.UtcNow.AddMinutes(-rnd.Next(10, 2800)).ToString("o"),
                ErpModule = "FI", Screen = "Cost Centre Lookup", LovName = "COST_CENTRE",
                ApiController = "Lov", ApiAction = "Get", ApiEndpoint = "/api/lov/cost-centre",
                Sql = new SqlErrorInfo
                {
                    Number = 207, Severity = 16, State = 1, ObjectName = "usp_GetCostCentreLov",
                    LineNumber = 12, ServerName = "ERP-SQL01", DatabaseName = "ERP_PROD", SchemaName = "common"
                },
                User = new UserContext { ProfileId = ProfileIdOf(users[i % users.Length]), Name = users[i % users.Length] },
                CorrelationId = Guid.NewGuid().ToString(),
                Environment = "Demo", AppVersion = "2026.3.1",
                StackTrace = "   at Erp.Common.LovRepository.Load(String lovCode) in C:\\build\\src\\LovRepository.cs:line 41"
            });
        }

        // A handful of one-off faults across other layers, so the dashboard
        // breakdown is not a single bar.
        var oneOffs = new (string Layer, string Category, string Severity, string Type, string Msg, string Module, string Screen)[]
        {
            (ErrorLayers.Angular, "angular_runtime", "high", "TypeError",
                "Cannot read properties of undefined (reading 'netAmount')", "SD", "Sales Order Entry"),
            (ErrorLayers.Angular, "chunk_load", "high", "ChunkLoadError",
                "Loading chunk 482 failed.", "HR", "Leave Request"),
            (ErrorLayers.Http, "http_server", "critical", "HttpErrorResponse",
                "500 Internal Server Error on /api/purchase-orders", "MM", "Purchase Order"),
            (ErrorLayers.WebApi, "api_unhandled", "critical", "System.NullReferenceException",
                "Object reference not set to an instance of an object.", "MM", "Purchase Order"),
            (ErrorLayers.Business, "business_rule", "low", "Erp.Core.CreditLimitBusinessException",
                "Customer credit limit exceeded by 12,400.00", "SD", "Sales Order Entry"),
            (ErrorLayers.Angular, "validation", "low", "Error",
                "Validation failed on PurchaseOrderHeader (3 field(s))", "MM", "Purchase Order"),
        };

        foreach (var o in oneOffs)
        {
            var seedUser = users[rnd.Next(users.Length)];
            var fp = Fingerprint.Compute(new Fingerprint.Input
            {
                Layer = o.Layer, Category = o.Category, ExceptionType = o.Type,
                Message = o.Msg, ErpModule = o.Module, Screen = o.Screen
            });
            Capture(new ErrorEnvelope
            {
                FingerprintHash = fp.Hash, SignatureText = fp.Signature,
                Layer = o.Layer, Category = o.Category, Severity = o.Severity,
                ExceptionType = o.Type, Message = o.Msg, NormalizedMessage = fp.NormalizedMessage,
                OccurredUtc = DateTime.UtcNow.AddMinutes(-rnd.Next(5, 4000)).ToString("o"),
                ErpModule = o.Module, Screen = o.Screen,
                User = new UserContext { ProfileId = ProfileIdOf(seedUser), Name = seedUser },
                CorrelationId = Guid.NewGuid().ToString(),
                Environment = "Demo", AppVersion = "2026.3.1",
                Client = new ClientInfo { BrowserName = "Chrome", BrowserVersion = "141", OsName = "Windows 10/11" }
            });
        }
    }

    /* ==================================================================== */
    /*  Plumbing                                                            */
    /* ==================================================================== */

    private bool IsTicketOpen(SqliteConnection c, SqliteTransaction? tx, long ticketId)
    {
        var row = QueryOne(c, tx, "SELECT Status FROM Ticket WHERE TicketId = $t", ("$t", ticketId));
        return row is not null && Statuses.TryGetValue((string)row["Status"]!, out var s) && !s.IsTerminal;
    }

    /// <summary>
    /// LinkedScam reference format: LS-ERM-TKT-YYMMDD-X / LS-ERM-ERR-YYMMDD-X,
    /// with the counter restarting each UTC day and ticket/error counted
    /// separately.
    ///
    /// Mirrors ERM.usp_NextReference, including the part that matters: the
    /// increment and the read are ONE statement, so two concurrent callers are
    /// serialised by the engine and cannot be handed the same number. A
    /// SELECT MAX+1 would look identical in a single-user demo and collide the
    /// first time two users hit an error in the same second.
    /// </summary>
    private string NextReference(SqliteConnection c, SqliteTransaction? tx, string refType, DateTime now)
    {
        var day = now.ToString("yyyy-MM-dd");
        int next;

        // UPDATE ... RETURNING is the SQLite equivalent of the T-SQL
        // UPDATE ... OUTPUT: atomic increment-and-read.
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = "UPDATE Counter SET Value = Value + 1 "
                            + "WHERE Name = $n RETURNING Value";
            if (tx is not null) cmd.Transaction = tx;
            cmd.Parameters.AddWithValue("$n", refType + "|" + day);
            var scalar = cmd.ExecuteScalar();

            if (scalar is null || scalar is DBNull)
            {
                // First reference of the day for this type. INSERT OR IGNORE
                // then re-run, so a lost race resolves rather than throwing -
                // the same shape as the duplicate-key retry in the T-SQL.
                Exec(c, tx, "INSERT OR IGNORE INTO Counter (Name, Value) VALUES ($n, 0)",
                    ("$n", refType + "|" + day));

                using var retry = c.CreateCommand();
                retry.CommandText = "UPDATE Counter SET Value = Value + 1 "
                                  + "WHERE Name = $n RETURNING Value";
                if (tx is not null) retry.Transaction = tx;
                retry.Parameters.AddWithValue("$n", refType + "|" + day);
                next = Convert.ToInt32(retry.ExecuteScalar());
            }
            else
            {
                next = Convert.ToInt32(scalar);
            }
        }

        // Counter is NOT zero-padded: the standard's examples are -1, -2, -3.
        return $"LS-ERM-{refType}-{now:yyMMdd}-{next}";
    }

    private static string Iso(DateTime utc) => utc.ToString("yyyy-MM-ddTHH:mm:ss.fffZ");

    private static DateTime? ParseUtc(string? value)
        => DateTime.TryParse(value, null, System.Globalization.DateTimeStyles.AdjustToUniversal
            | System.Globalization.DateTimeStyles.AssumeUniversal, out var d) ? d : null;

    private static string? Json(object? value)
        => value is null ? null : JsonSerializer.Serialize(value);

    private static object? Parse(string? json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        try { return JsonSerializer.Deserialize<JsonElement>(json); } catch { return null; }
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max];

    private static void Exec(SqliteConnection c, string sql) => Exec(c, null, sql);

    private static void Exec(SqliteConnection c, SqliteTransaction? tx, string sql,
        params (string Name, object? Value)[] parameters)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        if (tx is not null) cmd.Transaction = tx;
        foreach (var (n, v) in parameters) cmd.Parameters.AddWithValue(n, v ?? DBNull.Value);
        cmd.ExecuteNonQuery();
    }

    private static long ExecScalarLong(SqliteConnection c, SqliteTransaction? tx, string sql,
        params (string Name, object? Value)[] parameters)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        if (tx is not null) cmd.Transaction = tx;
        foreach (var (n, v) in parameters) cmd.Parameters.AddWithValue(n, v ?? DBNull.Value);
        var result = cmd.ExecuteScalar();
        return result is null or DBNull ? 0 : Convert.ToInt64(result);
    }

    private static List<Dictionary<string, object?>> Query(SqliteConnection c, SqliteTransaction? tx,
        string sql, params (string Name, object? Value)[] parameters)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        if (tx is not null) cmd.Transaction = tx;
        foreach (var (n, v) in parameters) cmd.Parameters.AddWithValue(n, v ?? DBNull.Value);

        var rows = new List<Dictionary<string, object?>>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < reader.FieldCount; i++)
                // null, NOT DBNull.Value: System.Text.Json serialises DBNull
                // as an empty object, which reaches the UI as "[object Object]".
                row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            rows.Add(row);
        }
        return rows;
    }

    private static Dictionary<string, object?>? QueryOne(SqliteConnection c, SqliteTransaction? tx,
        string sql, params (string Name, object? Value)[] parameters)
        => Query(c, tx, sql, parameters).FirstOrDefault();

    /// <summary>
    /// Column read that returns null for a column the result set does not
    /// contain, rather than throwing KeyNotFoundException.
    ///
    /// Added after a real failure: this mirror read ResolutionNotes, which the
    /// demo schema did not have, and the KeyNotFoundException surfaced to the
    /// browser as a 500 on the end-user ticket panel.
    /// </summary>
    private static object? Val(Dictionary<string, object?> row, string column)
        => row.TryGetValue(column, out var v) ? v : null;
}
