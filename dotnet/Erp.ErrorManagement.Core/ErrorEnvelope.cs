using System;
using System.Collections.Generic;
using Newtonsoft.Json;

namespace Erp.ErrorManagement
{
    /// <summary>
    /// The wire contract shared by every capture point.  Property names are the
    /// JSON names that ERM.usp_Error_Capture shreds with OPENJSON, and the
    /// same names the Angular library sends - keep this file, the TypeScript
    /// models/error-envelope.ts and script 004 in step.
    /// </summary>
    public class ErrorEnvelope
    {
        [JsonProperty("fingerprintHash")] public string FingerprintHash { get; set; }
        [JsonProperty("signatureText")]   public string SignatureText { get; set; }

        [JsonProperty("layer")]    public string Layer { get; set; }
        [JsonProperty("category")] public string Category { get; set; }
        [JsonProperty("severity")] public string Severity { get; set; }

        [JsonProperty("exceptionType")]     public string ExceptionType { get; set; }
        [JsonProperty("message")]           public string Message { get; set; }
        [JsonProperty("normalizedMessage")] public string NormalizedMessage { get; set; }

        [JsonProperty("occurredUtc")]            public string OccurredUtc { get; set; }
        [JsonProperty("occurredLocal")]          public string OccurredLocal { get; set; }
        [JsonProperty("clientUtcOffsetMinutes")] public int? ClientUtcOffsetMinutes { get; set; }

        [JsonProperty("erpModule")]  public string ErpModule { get; set; }
        [JsonProperty("screen")]     public string Screen { get; set; }
        [JsonProperty("routeUrl")]   public string RouteUrl { get; set; }
        [JsonProperty("component")]  public string Component { get; set; }
        [JsonProperty("actionName")] public string ActionName { get; set; }
        [JsonProperty("formName")]   public string FormName { get; set; }
        [JsonProperty("lovName")]    public string LovName { get; set; }

        [JsonProperty("apiApplication")] public string ApiApplication { get; set; }
        [JsonProperty("apiController")]  public string ApiController { get; set; }
        [JsonProperty("apiAction")]      public string ApiAction { get; set; }
        [JsonProperty("apiEndpoint")]    public string ApiEndpoint { get; set; }
        [JsonProperty("httpMethod")]     public string HttpMethod { get; set; }
        [JsonProperty("httpStatusCode")] public int? HttpStatusCode { get; set; }
        [JsonProperty("durationMs")]     public int? DurationMs { get; set; }

        [JsonProperty("sql")]    public SqlErrorInfo Sql { get; set; }
        [JsonProperty("user")]   public UserContext User { get; set; }
        [JsonProperty("client")] public ClientInfo Client { get; set; }

        [JsonProperty("correlationId")]        public string CorrelationId { get; set; }
        [JsonProperty("requestId")]            public string RequestId { get; set; }
        [JsonProperty("parentErrorReference")] public string ParentErrorReference { get; set; }

        [JsonProperty("environment")] public string Environment { get; set; }
        [JsonProperty("appVersion")]  public string AppVersion { get; set; }
        [JsonProperty("machineName")] public string MachineName { get; set; }

        [JsonProperty("stackTrace")]          public string StackTrace { get; set; }
        [JsonProperty("innerExceptionChain")] public string InnerExceptionChain { get; set; }

        [JsonProperty("requestPayload")]   public object RequestPayload { get; set; }
        [JsonProperty("responsePayload")]  public object ResponsePayload { get; set; }
        [JsonProperty("validationErrors")] public List<ValidationErrorItem> ValidationErrors { get; set; }
        [JsonProperty("breadcrumbs")]      public List<Breadcrumb> Breadcrumbs { get; set; }
        [JsonProperty("customData")]       public Dictionary<string, object> CustomData { get; set; }
    }

    public class SqlErrorInfo
    {
        [JsonProperty("number")]       public int? Number { get; set; }
        [JsonProperty("severity")]     public byte? Severity { get; set; }
        [JsonProperty("state")]        public byte? State { get; set; }
        [JsonProperty("objectName")]   public string ObjectName { get; set; }
        [JsonProperty("lineNumber")]   public int? LineNumber { get; set; }
        [JsonProperty("serverName")]   public string ServerName { get; set; }
        [JsonProperty("databaseName")] public string DatabaseName { get; set; }
        [JsonProperty("schemaName")]   public string SchemaName { get; set; }
        [JsonProperty("statement")]    public string Statement { get; set; }
    }

    public class UserContext
    {
        /// <summary>
        /// The ERP's own UserProfileID - the value
        /// <c>generic_service.GetUserProfileKey()</c> returns in Angular, and the
        /// value ATC's APIs and stored procedures already pass around as
        /// CreatedBy / UpdatedBy / UserProfileID.
        ///
        /// -1 means there is no ERP user behind this error: a public page, or a
        /// browser with no token. It is never null on the wire, because a
        /// missing value and "no user" are the same thing here and having two
        /// spellings of it invites a null check somebody forgets.
        /// </summary>
        [JsonProperty("profileId")]   public int ProfileId { get; set; } = ErpUser.None;

        /// <summary>Display text only. Never used to identify or authorise.</summary>
        [JsonProperty("name")]        public string Name { get; set; }
        [JsonProperty("displayName")] public string DisplayName { get; set; }
        [JsonProperty("tenantId")]    public string TenantId { get; set; }
        [JsonProperty("sessionId")]   public string SessionId { get; set; }
        [JsonProperty("clientIp")]    public string ClientIp { get; set; }
    }

    public class ClientInfo
    {
        [JsonProperty("browserName")]      public string BrowserName { get; set; }
        [JsonProperty("browserVersion")]   public string BrowserVersion { get; set; }
        [JsonProperty("osName")]           public string OsName { get; set; }
        [JsonProperty("deviceType")]       public string DeviceType { get; set; }
        [JsonProperty("screenResolution")] public string ScreenResolution { get; set; }
        [JsonProperty("locale")]           public string Locale { get; set; }
    }

    public class ValidationErrorItem
    {
        [JsonProperty("control")] public string Control { get; set; }
        [JsonProperty("rule")]    public string Rule { get; set; }
        [JsonProperty("detail")]  public Dictionary<string, object> Detail { get; set; }
    }

    public class Breadcrumb
    {
        [JsonProperty("at")]      public string At { get; set; }
        [JsonProperty("kind")]    public string Kind { get; set; }
        [JsonProperty("message")] public string Message { get; set; }
        [JsonProperty("data")]    public Dictionary<string, object> Data { get; set; }
    }

    /// <summary>What usp_Error_Capture returns.</summary>
    public class ErrorCaptureResult
    {
        [JsonProperty("errorReference")]    public string ErrorReference { get; set; }
        [JsonProperty("occurrenceId")]      public long? OccurrenceId { get; set; }
        [JsonProperty("fingerprintId")]     public long? FingerprintId { get; set; }
        [JsonProperty("shouldNotifyUser")]  public bool ShouldNotifyUser { get; set; }
        [JsonProperty("autoTicketNumber")]  public string AutoTicketNumber { get; set; }
        [JsonProperty("isKnownIssue")]      public bool IsKnownIssue { get; set; }

        /// <summary>
        /// Whether this caller may turn the error into a ticket.
        ///
        /// Set by the API, not the database: it depends on whether the request
        /// was authenticated, which the store knows nothing about. The dialog
        /// hides its "Report issue" button when this is false, because offering
        /// a button that is going to be refused is worse than not offering one.
        /// </summary>
        [JsonProperty("canCreateTicket")]   public bool CanCreateTicket { get; set; } = true;
    }

    /// <summary>One row in the end user's "My Tickets" list.</summary>
    public class UserTicketSummary
    {
        [JsonProperty("ticketNumber")] public string TicketNumber { get; set; }
        [JsonProperty("title")]        public string Title { get; set; }
        [JsonProperty("statusCode")]   public string StatusCode { get; set; }
        [JsonProperty("statusName")]   public string StatusName { get; set; }
        [JsonProperty("isOpen")]       public bool IsOpen { get; set; }
        [JsonProperty("severityName")] public string SeverityName { get; set; }
        [JsonProperty("createdUtc")]   public DateTime? CreatedUtc { get; set; }
        [JsonProperty("resolvedUtc")]  public DateTime? ResolvedUtc { get; set; }
        [JsonProperty("closedUtc")]    public DateTime? ClosedUtc { get; set; }
        [JsonProperty("erpModule")]    public string ErpModule { get; set; }
        [JsonProperty("latestUpdate")] public string LatestUpdate { get; set; }
        /// <summary>True when support is waiting on the user to reply.</summary>
        [JsonProperty("awaitingYourReply")] public bool AwaitingYourReply { get; set; }
    }

    /// <summary>
    /// The end user's view of one of their own tickets.
    ///
    /// Note what is absent: no stack trace, no SQL object, no exception type, no
    /// assignee, no fingerprint, no internal notes. Those are removed by the
    /// stored procedure, not by the UI - filtering in the UI would still have
    /// sent them to the browser.
    /// </summary>
    public class UserTicketDetail
    {
        [JsonProperty("ticketNumber")]   public string TicketNumber { get; set; }
        [JsonProperty("title")]          public string Title { get; set; }
        [JsonProperty("statusCode")]     public string StatusCode { get; set; }
        [JsonProperty("statusName")]     public string StatusName { get; set; }
        [JsonProperty("isOpen")]         public bool IsOpen { get; set; }
        [JsonProperty("severityName")]   public string SeverityName { get; set; }
        [JsonProperty("erpModule")]      public string ErpModule { get; set; }
        [JsonProperty("createdUtc")]     public DateTime? CreatedUtc { get; set; }
        [JsonProperty("firstResponseUtc")] public DateTime? FirstResponseUtc { get; set; }
        [JsonProperty("resolvedUtc")]    public DateTime? ResolvedUtc { get; set; }
        [JsonProperty("closedUtc")]      public DateTime? ClosedUtc { get; set; }
        [JsonProperty("errorReference")] public string ErrorReference { get; set; }
        [JsonProperty("yourDescription")] public string YourDescription { get; set; }
        [JsonProperty("resolutionNotes")] public string ResolutionNotes { get; set; }
        [JsonProperty("awaitingYourReply")] public bool AwaitingYourReply { get; set; }
        [JsonProperty("canComment")]     public bool CanComment { get; set; }
        [JsonProperty("history")]        public List<UserTicketHistoryEntry> History { get; set; }
        [JsonProperty("comments")]       public List<UserTicketComment> Comments { get; set; }
    }

    public class UserTicketHistoryEntry
    {
        [JsonProperty("sequenceNo")] public int SequenceNo { get; set; }
        [JsonProperty("statusName")] public string StatusName { get; set; }
        [JsonProperty("changedUtc")] public DateTime ChangedUtc { get; set; }
        [JsonProperty("comments")]   public string Comments { get; set; }
    }

    public class UserTicketComment
    {
        [JsonProperty("authorRole")] public string AuthorRole { get; set; }
        [JsonProperty("authorName")] public string AuthorName { get; set; }
        [JsonProperty("commentText")] public string CommentText { get; set; }
        [JsonProperty("createdUtc")] public DateTime CreatedUtc { get; set; }
    }

    public class TicketCreateResult
    {
        [JsonProperty("ticketNumber")]    public string TicketNumber { get; set; }
        [JsonProperty("ticketId")]        public long TicketId { get; set; }
        [JsonProperty("wasDeduplicated")] public bool WasDeduplicated { get; set; }
    }

    /// <summary>Layer codes - must match ERM.ERM_AppLayer.Code.</summary>
    public static class ErrorLayers
    {
        public const string Angular        = "angular";
        public const string Http           = "http";
        public const string WebApi         = "webapi";
        public const string Business       = "business";
        public const string Data           = "data";
        public const string Database       = "database";
        public const string Integration    = "integration";
        public const string Infrastructure = "infrastructure";
    }

    /// <summary>Category codes - must match ERM.ERM_ErrorCategory.Code.</summary>
    public static class ErrorCategories
    {
        public const string ApiUnhandled   = "api_unhandled";
        public const string BusinessRule   = "business_rule";
        public const string Concurrency    = "concurrency";
        public const string Serialization  = "serialization";
        public const string Auth           = "auth";
        public const string SqlError       = "sql_error";
        public const string SqlProcedure   = "sql_procedure";
        public const string SqlConstraint  = "sql_constraint";
        public const string SqlDeadlock    = "sql_deadlock";
        public const string SqlTimeout     = "sql_timeout";
        public const string DbConnection   = "db_connection";
        public const string Integration    = "integration";
        public const string Configuration  = "configuration";
        public const string Unclassified   = "unclassified";
    }

    /// <summary>Severity codes - must match ERM.ERM_Severity.Code.</summary>
    public static class ErrorSeverities
    {
        public const string Critical = "critical";
        public const string High     = "high";
        public const string Medium   = "medium";
        public const string Low      = "low";
        public const string Info     = "info";
    }
}
