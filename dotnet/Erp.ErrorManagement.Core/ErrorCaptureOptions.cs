using System;
using System.Collections.Generic;

namespace Erp.ErrorManagement
{
    /// <summary>
    /// Host-supplied settings.  Anything an administrator should be able to
    /// change at runtime lives in ERM.Setting instead; this is the
    /// deployment-time configuration only.
    /// </summary>
    public class ErrorCaptureOptions
    {
        /// <summary>
        /// Connection string for the error store.
        ///
        /// CAN be the ERP's own connection string - the framework only ever
        /// touches its own schema - but a separate login with EXECUTE on
        /// ERM and nothing else is the recommendation (db/006_security.sql).
        /// It also lets the error store be moved to its own database later
        /// without touching a line of application code.
        /// </summary>
        public string ConnectionString { get; set; }

        /// <summary>'Production' | 'UAT' | 'Development'.</summary>
        public string Environment { get; set; } = "Production";

        /// <summary>Stamped on every envelope this application produces.</summary>
        public string ApplicationName { get; set; } = "ERP.Api";

        public string AppVersion { get; set; }

        /// <summary>Default ERP module when the request carries no X-Erp-Module header.</summary>
        public string DefaultErpModule { get; set; }

        /// <summary>Command timeout for the capture call itself, in seconds.</summary>
        public int CommandTimeoutSeconds { get; set; } = 10;

        /// <summary>
        /// Persist the (redacted) request body.  Off by default on the server
        /// side: the browser already sends it, and storing it twice doubles the
        /// payload for no diagnostic gain.
        /// </summary>
        public bool CaptureRequestBody { get; set; } = false;

        /// <summary>Maximum request body bytes to buffer before giving up on capturing it.</summary>
        public int MaxRequestBodyBytes { get; set; } = 64 * 1024;

        public int MaxStackTraceChars { get; set; } = 20000;

        /// <summary>Header names whose values may be stored in full.</summary>
        public List<string> HeaderAllowList { get; set; } = new List<string>
        {
            "content-type", "accept", "accept-language", "user-agent", "referer",
            "x-correlation-id", "x-request-id", "x-erp-module", "x-erp-screen", "x-app-version"
        };

        /// <summary>Query-string and body keys whose values may be stored in full.</summary>
        public List<string> PayloadKeyAllowList { get; set; } = new List<string>
        {
            "id", "code", "documentno", "status", "modulecode", "screencode", "action",
            "rowversion", "page", "pagesize", "sort", "sortdirection", "lovcode", "fromdate", "todate"
        };

        /// <summary>Request paths never captured (the capture endpoint itself, health probes).</summary>
        public List<string> IgnorePathFragments { get; set; } = new List<string>
        {
            "/api/error-management/", "/health", "/swagger", "/favicon.ico"
        };

        /// <summary>
        /// Exception types never captured, by full or simple name.  Use for the
        /// ERP's own "this is a user message, not a fault" exception type.
        /// </summary>
        public List<string> IgnoreExceptionTypes { get; set; } = new List<string>();

        /// <summary>
        /// Resolve the signed-in user.  Left to the host because every ERP
        /// stores identity differently.  Exceptions from this are swallowed.
        ///
        /// Return null for an unauthenticated request - that is a normal,
        /// expected outcome on a public page, not a failure.  The occurrence is
        /// still captured, with the user fields empty.
        /// </summary>
        public Func<UserContext> UserProvider { get; set; }

        /// <summary>
        /// Accept capture from unauthenticated callers.
        ///
        /// Required when any ERP page is public: an error on a public login or
        /// self-service page is exactly the kind you most need to see, and the
        /// browser has no token to send.  Rate-limited per client IP when
        /// enabled - see AnonymousCaptureThrottle for why that is not optional.
        /// </summary>
        public bool AllowAnonymousCapture { get; set; } = true;

        /// <summary>Sustained anonymous envelopes accepted per client IP per minute.</summary>
        public int AnonymousCaptureRatePerMinute { get; set; } = 60;

        /// <summary>Anonymous burst size per client IP.</summary>
        public int AnonymousCaptureBurst { get; set; } = 20;

        /// <summary>
        /// Allow an unauthenticated user to raise a TICKET, not just have the
        /// error captured.
        ///
        /// OFF by default, and that default is a real decision rather than
        /// caution: a ticket carries free text, lands in a support queue and
        /// notifies people.  An open ticket-creation endpoint on a public page
        /// is a spam channel aimed at your support team.
        ///
        /// With this off, an anonymous user still sees the dialog and the error
        /// reference - which is enough for them to quote it to support, and the
        /// occurrence is already in the store waiting.  The dialog hides its
        /// "Report issue" button when the API says tickets are unavailable.
        /// </summary>
        public bool AllowAnonymousTicketCreation { get; set; } = false;

        /// <summary>
        /// Token role claims that additionally grant support-console access,
        /// on top of the ERM.SupportUser roster.
        ///
        /// Empty by default, which means the roster is the only source. Set it
        /// if you would rather drive authorisation from your identity provider:
        /// a caller holding any of these roles is treated as an administrator
        /// even with no roster row.
        ///
        /// Both sources are OR'd. That is a deliberate choice and worth
        /// understanding: it means adding a role here GRANTS access, and
        /// removing someone from the roster does NOT revoke it if they still
        /// hold the claim. If you need the roster to be authoritative, leave
        /// this empty.
        /// </summary>
        public List<string> SupportRoleClaims { get; set; } = new List<string>();

        /// <summary>
        /// Claim type to read those roles from. Defaults to the standard role
        /// claim; override for a bespoke token.
        /// </summary>
        public string RoleClaimType { get; set; } = "http://schemas.microsoft.com/ws/2008/06/identity/claims/role";

        /// <summary>
        /// Role code assumed for a caller who is authorised by claim rather
        /// than by roster. Must exist in ERM.SupportRole.
        /// </summary>
        public string ClaimAuthorisedRoleCode { get; set; } = "administrator";

        /// <summary>Last chance to change or drop an envelope.  Return null to discard.</summary>
        public Func<ErrorEnvelope, ErrorEnvelope> BeforeSend { get; set; }

        /// <summary>
        /// Where to write when the error store itself is unreachable.  Defaults
        /// to the Windows Event Log on .NET Framework and the ILogger on .NET 8.
        /// Never left as a silent no-op: a capture pipeline that fails quietly
        /// is indistinguishable from an ERP with no errors.
        /// </summary>
        public Action<string, Exception> FallbackLogger { get; set; }

        /// <summary>
        /// Response body returned to the browser for an unhandled exception.
        /// Contains the error reference and nothing else - no stack trace, no
        /// SQL text, no server name.
        /// </summary>
        public Func<string, object> UserFacingResponseFactory { get; set; } =
            errorReference => new
            {
                message = "We encountered an unexpected problem while processing your request.",
                errorReference,
                canReportIssue = errorReference != null
            };

        public void Validate()
        {
            if (string.IsNullOrWhiteSpace(ConnectionString))
                throw new InvalidOperationException(
                    "ErrorCaptureOptions.ConnectionString is required. " +
                    "Point it at the database that hosts the ERM schema.");
        }
    }
}
