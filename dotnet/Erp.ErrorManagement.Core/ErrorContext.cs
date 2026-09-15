using System;
using System.Threading;

namespace Erp.ErrorManagement
{
    /// <summary>
    /// Per-request ambient context.
    ///
    /// This is what lets an exception thrown five layers deep in a repository
    /// know which correlation id, ERP module and screen it belongs to WITHOUT
    /// every method signature in the ERP growing a context parameter.  The
    /// message handler (Web API 2) or middleware (ASP.NET Core) fills it in at
    /// the start of the request; the exception logger reads it at the end.
    ///
    /// AsyncLocal rather than [ThreadStatic] or HttpContext.Items: it follows
    /// async/await continuations across thread-pool threads, which
    /// [ThreadStatic] does not, and it works in a background task where
    /// HttpContext.Current is null.  That combination is exactly where a
    /// legacy Web API 2 codebase does its long-running work.
    /// </summary>
    public static class ErrorContext
    {
        private static readonly AsyncLocal<ErrorContextValues> Current = new AsyncLocal<ErrorContextValues>();

        public class ErrorContextValues
        {
            public Guid CorrelationId { get; set; }
            public Guid? RequestId { get; set; }
            public string ErpModule { get; set; }
            public string Screen { get; set; }
            public string ApiController { get; set; }
            public string ApiAction { get; set; }
            public string ApiEndpoint { get; set; }
            public string HttpMethod { get; set; }
            public string UserId { get; set; }
            public string UserName { get; set; }
            public string UserDisplayName { get; set; }
            public string TenantId { get; set; }
            public string SessionId { get; set; }
            public string ClientIp { get; set; }
            public string AppVersion { get; set; }
            public DateTime StartedUtc { get; set; }
        }

        public static ErrorContextValues Values => Current.Value;

        public static void Begin(ErrorContextValues values)
        {
            if (values == null) throw new ArgumentNullException(nameof(values));
            if (values.CorrelationId == Guid.Empty) values.CorrelationId = Guid.NewGuid();
            if (values.StartedUtc == default(DateTime)) values.StartedUtc = DateTime.UtcNow;
            Current.Value = values;
        }

        public static void End()
        {
            Current.Value = null;
        }

        public static Guid CorrelationId => Current.Value?.CorrelationId ?? Guid.Empty;

        /// <summary>
        /// Elapsed milliseconds since the request started, for the DurationMs
        /// field.  Returns null outside a request.
        /// </summary>
        public static int? ElapsedMs()
        {
            var v = Current.Value;
            if (v == null || v.StartedUtc == default(DateTime)) return null;
            var ms = (DateTime.UtcNow - v.StartedUtc).TotalMilliseconds;
            return ms < 0 || ms > int.MaxValue ? (int?)null : (int)ms;
        }

        /// <summary>
        /// Let a service enrich the context mid-request - e.g. a business layer
        /// that knows the ERP module better than the route did.
        /// </summary>
        public static void Enrich(Action<ErrorContextValues> enrich)
        {
            var v = Current.Value;
            if (v == null || enrich == null) return;
            try
            {
                enrich(v);
            }
            catch
            {
                // Enrichment is a convenience, never a failure mode.
            }
        }
    }
}
