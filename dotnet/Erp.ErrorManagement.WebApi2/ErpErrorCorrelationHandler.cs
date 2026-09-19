using System;
using System.Linq;
using System.Net.Http;
using System.Security.Claims;
using System.Threading;
using System.Threading.Tasks;
using System.Web;

namespace Erp.ErrorManagement.WebApi2
{
    /// <summary>
    /// A Web API 2 message handler that opens the ambient ErrorContext for every
    /// request and stamps the correlation id onto the response.
    ///
    /// This runs BEFORE routing, so it sees requests that never reach a
    /// controller (404s, model-binding failures, authentication rejections) -
    /// which is precisely where a filter-based approach has a blind spot.
    ///
    /// Registration, once, in WebApiConfig.Register:
    ///
    ///     config.MessageHandlers.Add(new ErpErrorCorrelationHandler());
    ///
    /// That is the entire change to the existing API's startup for correlation.
    /// </summary>
    public class ErpErrorCorrelationHandler : DelegatingHandler
    {
        public const string CorrelationHeader = "X-Correlation-Id";
        public const string RequestHeader = "X-Request-Id";
        public const string ModuleHeader = "X-Erp-Module";
        public const string ScreenHeader = "X-Erp-Screen";
        public const string AppVersionHeader = "X-App-Version";

        private readonly string _defaultModule;
        private readonly ErrorCaptureOptions _options;

        /// <param name="options">
        /// Supplies the UserProfileID resolution rules. Optional: with no
        /// options the built-in header and claim defaults still apply, so the
        /// handler works standalone. The bootstrapper passes the real ones.
        /// </param>
        public ErpErrorCorrelationHandler(string defaultModule = null, ErrorCaptureOptions options = null)
        {
            _defaultModule = defaultModule;
            _options = options ?? new ErrorCaptureOptions();
        }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var values = new ErrorContext.ErrorContextValues
            {
                CorrelationId = ReadGuidHeader(request, CorrelationHeader) ?? Guid.NewGuid(),
                RequestId = ReadGuidHeader(request, RequestHeader) ?? Guid.NewGuid(),
                ErpModule = ReadHeader(request, ModuleHeader) ?? _defaultModule,
                Screen = ReadHeader(request, ScreenHeader),
                AppVersion = ReadHeader(request, AppVersionHeader),
                HttpMethod = request.Method.Method,
                ApiEndpoint = request.RequestUri?.AbsolutePath,
                ClientIp = GetClientIp(request),
                StartedUtc = DateTime.UtcNow
            };

            ApplyIdentity(values, request);

            ErrorContext.Begin(values);

            try
            {
                var response = await base.SendAsync(request, cancellationToken).ConfigureAwait(false);

                // Echo the correlation id back.  Support can then ask the user
                // for the value their browser saw and find every layer's record
                // of the same request - including the ones that were logged but
                // never surfaced.
                if (response != null && !response.Headers.Contains(CorrelationHeader))
                {
                    response.Headers.TryAddWithoutValidation(
                        CorrelationHeader, values.CorrelationId.ToString());
                }

                return response;
            }
            finally
            {
                ErrorContext.End();
            }
        }

        /// <summary>
        /// Populate the user fields from whatever identity the pipeline has
        /// established by this point.
        ///
        /// Deliberately defensive and deliberately generic: this handler runs
        /// before authorisation in some configurations, so there may be no
        /// identity yet, and every ERP names its claims differently.  The
        /// authoritative resolution is ErrorCaptureOptions.UserProvider, which
        /// the host supplies; this is the fallback that makes the framework
        /// useful on day one without any wiring.
        /// </summary>
        private void ApplyIdentity(ErrorContext.ErrorContextValues values, HttpRequestMessage request)
        {
            try
            {
                // The ERP UserProfileID comes from the request context first -
                // the same value the controller is about to write into its own
                // CreatedBy. Doing it the other way round, deriving it from a
                // token claim, would mean the framework and the ERP could
                // disagree about who did something, and the framework would be
                // the one that was wrong.
                values.UserProfileId = ResolveUserProfileId(request);

                var principal = HttpContext.Current?.User ?? Thread.CurrentPrincipal;
                var identity = principal?.Identity;
                if (identity == null || !identity.IsAuthenticated) return;

                values.UserName = identity.Name;

                if (identity is ClaimsIdentity claims)
                {
                    values.UserDisplayName =
                        FirstClaim(claims, "name") ??
                        FirstClaim(claims, ClaimTypes.GivenName) ??
                        identity.Name;

                    values.TenantId =
                        FirstClaim(claims, "tid") ??
                        FirstClaim(claims, "tenantId") ??
                        FirstClaim(claims, "companyId");
                }

                var sessionId = HttpContext.Current?.Session?.SessionID;
                if (!string.IsNullOrEmpty(sessionId)) values.SessionId = sessionId;
            }
            catch
            {
                // Identity resolution is best-effort.  An anonymous error record
                // is still a useful error record; a handler that throws here
                // takes down every request in the API.
            }
        }

        /// <summary>
        /// Provider, then header, then claim - and -1 if none of them produced
        /// a real ERP user.
        ///
        /// Anything that is not a positive integer is discarded rather than
        /// coerced. "0", "", "null" and "abc" all mean the caller did not tell
        /// us, and quietly turning any of them into a user id would attribute
        /// somebody's error to whoever owns that id.
        /// </summary>
        private int ResolveUserProfileId(HttpRequestMessage request)
        {
            if (_options.UserProfileIdProvider != null)
            {
                try
                {
                    var supplied = ErpUser.Normalize(_options.UserProfileIdProvider());
                    if (ErpUser.IsReal(supplied)) return supplied;
                }
                catch
                {
                    // The host's own resolver threw. Fall through - capturing
                    // the error anonymously beats not capturing it.
                }
            }

            if (_options.UserProfileIdHeaderNames != null && request != null)
            {
                foreach (var header in _options.UserProfileIdHeaderNames)
                {
                    var raw = ReadHeader(request, header);
                    if (int.TryParse(raw, out var parsed) && ErpUser.IsReal(parsed)) return parsed;
                }
            }

            if (_options.UserProfileIdClaimTypes != null)
            {
                var principal = HttpContext.Current?.User ?? Thread.CurrentPrincipal;
                if (principal?.Identity is ClaimsIdentity claims)
                {
                    foreach (var claimType in _options.UserProfileIdClaimTypes)
                    {
                        var raw = FirstClaim(claims, claimType);
                        if (int.TryParse(raw, out var parsed) && ErpUser.IsReal(parsed)) return parsed;
                    }
                }
            }

            return ErpUser.None;
        }

        private static string FirstClaim(ClaimsIdentity identity, string type)
        {
            return identity.Claims.FirstOrDefault(c =>
                string.Equals(c.Type, type, StringComparison.OrdinalIgnoreCase))?.Value;
        }

        private static string ReadHeader(HttpRequestMessage request, string name)
        {
            if (!request.Headers.TryGetValues(name, out var values)) return null;
            var value = values.FirstOrDefault();
            if (string.IsNullOrWhiteSpace(value)) return null;
            // Header values are attacker-controlled; cap them so a 2 MB header
            // cannot become a 2 MB column value.
            return value.Length > 200 ? value.Substring(0, 200) : value;
        }

        private static Guid? ReadGuidHeader(HttpRequestMessage request, string name)
        {
            var raw = ReadHeader(request, name);
            return Guid.TryParse(raw, out var parsed) ? parsed : (Guid?)null;
        }

        /// <summary>
        /// The client IP as the server sees it.
        ///
        /// X-Forwarded-For is only consulted when the ERP is genuinely behind a
        /// reverse proxy - it is trivially spoofable otherwise.  The direct
        /// remote address is kept as well so the two can be compared.
        /// </summary>
        private static string GetClientIp(HttpRequestMessage request)
        {
            try
            {
                var context = HttpContext.Current;
                var remote = context?.Request?.UserHostAddress;

                if (request.Headers.TryGetValues("X-Forwarded-For", out var forwarded))
                {
                    var first = forwarded.FirstOrDefault()?.Split(',')[0].Trim();
                    if (!string.IsNullOrEmpty(first))
                        return remote == null ? first : first + " (via " + remote + ")";
                }

                return remote;
            }
            catch
            {
                return null;
            }
        }
    }
}
