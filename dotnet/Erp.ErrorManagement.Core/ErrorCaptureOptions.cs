using System;
using System.Collections.Generic;

namespace Erp.ErrorManagement
{
    /// <summary>
    /// Host-supplied settings.  Anything an administrator should be able to
    /// change at runtime lives in erp_err.Setting instead; this is the
    /// deployment-time configuration only.
    /// </summary>
    public class ErrorCaptureOptions
    {
        /// <summary>
        /// Connection string for the error store.
        ///
        /// CAN be the ERP's own connection string - the framework only ever
        /// touches its own schema - but a separate login with EXECUTE on
        /// erp_err and nothing else is the recommendation (db/006_security.sql).
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
        /// </summary>
        public Func<UserContext> UserProvider { get; set; }

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
                    "Point it at the database that hosts the erp_err schema.");
        }
    }
}
