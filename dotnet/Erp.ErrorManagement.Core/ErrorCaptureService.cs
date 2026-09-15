using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Erp.ErrorManagement
{
    /// <summary>
    /// Turns an Exception into an ErrorEnvelope and hands it to the store.
    ///
    /// Shared by the Web API 2 exception logger, the ASP.NET Core middleware,
    /// and anywhere in the ERP that wants to report a handled exception
    /// explicitly.  All three go through here so classification, redaction and
    /// fingerprinting happen once, in one place, identically.
    /// </summary>
    public class ErrorCaptureService
    {
        private readonly IErrorStore _store;
        private readonly ErrorCaptureOptions _options;
        private readonly Redactor _redactor;

        public ErrorCaptureService(IErrorStore store, ErrorCaptureOptions options)
        {
            _store = store ?? throw new ArgumentNullException(nameof(store));
            _options = options ?? throw new ArgumentNullException(nameof(options));
            _redactor = new Redactor(options.HeaderAllowList, options.PayloadKeyAllowList);
        }

        public Redactor Redactor => _redactor;
        public ErrorCaptureOptions Options => _options;

        public bool ShouldIgnore(Exception exception, string path)
        {
            if (exception == null) return true;

            if (!string.IsNullOrEmpty(path) &&
                _options.IgnorePathFragments.Any(f => path.IndexOf(f, StringComparison.OrdinalIgnoreCase) >= 0))
                return true;

            var type = exception.GetType();
            return _options.IgnoreExceptionTypes.Any(t =>
                string.Equals(t, type.FullName, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(t, type.Name, StringComparison.OrdinalIgnoreCase));
        }

        public ErrorEnvelope BuildEnvelope(
            Exception exception,
            IDictionary<string, string> requestHeaders = null,
            IDictionary<string, string> queryString = null,
            object requestBody = null,
            IDictionary<string, object> customData = null)
        {
            var classification = ExceptionClassifier.Classify(exception);
            var ctx = ErrorContext.Values;
            var now = DateTime.UtcNow;

            var stack = Redactor.ScrubText(
                ExceptionClassifier.Unwrap(exception)?.StackTrace, _options.MaxStackTraceChars);

            var fingerprint = Fingerprint.Compute(new Fingerprint.Input
            {
                Layer = classification.Layer,
                Category = classification.Category,
                ExceptionType = classification.ExceptionType,
                Message = classification.Message,
                StackTrace = stack,
                ErpModule = ctx?.ErpModule ?? _options.DefaultErpModule,
                Screen = ctx?.Screen,
                ApiController = ctx?.ApiController,
                ApiAction = ctx?.ApiAction,
                ApiEndpoint = ctx?.ApiEndpoint,
                SqlErrorNumber = classification.Sql?.Number,
                SqlObjectName = classification.Sql?.ObjectName
            });

            var user = ResolveUser(ctx);

            // The SQL diagnostics that matter but are not on the exception:
            // which database and schema the failing connection was actually
            // pointed at.  On a multi-schema ERP - exactly the case the brief
            // describes - "which schema was this" is the first question asked.
            var sql = classification.Sql;
            if (sql != null && string.IsNullOrEmpty(sql.DatabaseName))
            {
                sql.DatabaseName = TryGetDatabaseName(_options.ConnectionString);
            }

            var envelope = new ErrorEnvelope
            {
                FingerprintHash = fingerprint.Hash,
                SignatureText = fingerprint.Signature,

                Layer = classification.Layer,
                Category = classification.Category,
                Severity = classification.Severity,

                ExceptionType = classification.ExceptionType,
                Message = Redactor.ScrubText(classification.Message, 2000),
                NormalizedMessage = fingerprint.NormalizedMessage,

                OccurredUtc = now.ToString("o"),

                ErpModule = ctx?.ErpModule ?? _options.DefaultErpModule,
                Screen = ctx?.Screen,

                ApiApplication = _options.ApplicationName,
                ApiController = ctx?.ApiController,
                ApiAction = ctx?.ApiAction,
                ApiEndpoint = ctx?.ApiEndpoint,
                HttpMethod = ctx?.HttpMethod,
                HttpStatusCode = classification.HttpStatusCode,
                DurationMs = ErrorContext.ElapsedMs(),

                Sql = sql,
                User = user,

                CorrelationId = (ctx?.CorrelationId ?? Guid.NewGuid()).ToString(),
                RequestId = ctx?.RequestId?.ToString(),

                Environment = _options.Environment,
                AppVersion = ctx?.AppVersion ?? _options.AppVersion,
                MachineName = SafeMachineName(),

                StackTrace = stack,
                InnerExceptionChain = Redactor.ScrubText(
                    ExceptionClassifier.FlattenInnerChain(exception), 4000),

                CustomData = customData == null ? null : new Dictionary<string, object>(customData)
            };

            if (requestHeaders != null || queryString != null || requestBody != null)
            {
                envelope.RequestPayload = new Dictionary<string, object>
                {
                    ["url"] = ctx?.ApiEndpoint,
                    ["method"] = ctx?.HttpMethod,
                    ["headers"] = requestHeaders == null ? null : _redactor.RedactHeaders(requestHeaders),
                    ["query"] = queryString == null ? null : _redactor.RedactQuery(queryString),
                    ["body"] = _options.CaptureRequestBody && requestBody != null
                        ? _redactor.RedactObject(requestBody)
                        : null
                };
            }

            if (_options.BeforeSend != null)
            {
                try
                {
                    return _options.BeforeSend(envelope);
                }
                catch
                {
                    // A broken hook must not silence the error.
                    return envelope;
                }
            }

            return envelope;
        }

        public async Task<ErrorCaptureResult> CaptureAsync(
            Exception exception,
            string source,
            IDictionary<string, string> requestHeaders = null,
            IDictionary<string, string> queryString = null,
            object requestBody = null,
            IDictionary<string, object> customData = null,
            CancellationToken ct = default)
        {
            try
            {
                var envelope = BuildEnvelope(exception, requestHeaders, queryString, requestBody, customData);
                if (envelope == null) return null;
                return await _store.CaptureAsync(envelope, source, ct).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                try
                {
                    _options.FallbackLogger?.Invoke("Failed to build or store error envelope", ex);
                }
                catch
                {
                    /* nowhere left to report to */
                }
                return null;
            }
        }

        /// <summary>Capture an envelope that arrived from the browser, enriching it server-side.</summary>
        public async Task<ErrorCaptureResult> CaptureClientEnvelopeAsync(
            ErrorEnvelope envelope, string clientIp, CancellationToken ct = default)
        {
            if (envelope == null) return null;

            try
            {
                // The client is never trusted for identity or for its own IP.
                var ctx = ErrorContext.Values;
                var serverUser = ResolveUser(ctx);
                if (serverUser != null)
                {
                    envelope.User = envelope.User ?? new UserContext();
                    envelope.User.Id = serverUser.Id ?? envelope.User.Id;
                    envelope.User.Name = serverUser.Name ?? envelope.User.Name;
                    envelope.User.DisplayName = serverUser.DisplayName ?? envelope.User.DisplayName;
                    envelope.User.TenantId = serverUser.TenantId ?? envelope.User.TenantId;
                }
                if (envelope.User != null) envelope.User.ClientIp = clientIp;

                envelope.Environment = envelope.Environment ?? _options.Environment;
                envelope.MachineName = SafeMachineName();

                // Re-run the text scrub server-side.  An old cached bundle, or a
                // tampered-with client, could send anything; the store is
                // protected by its own sweep rather than by trusting the sender.
                envelope.Message = Redactor.ScrubText(envelope.Message, 2000);
                envelope.StackTrace = Redactor.ScrubText(envelope.StackTrace, _options.MaxStackTraceChars);
                envelope.InnerExceptionChain = Redactor.ScrubText(envelope.InnerExceptionChain, 4000);

                return await _store.CaptureAsync(envelope, "angular", ct).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                try
                {
                    _options.FallbackLogger?.Invoke("Failed to store client envelope", ex);
                }
                catch
                {
                    /* nowhere left to report to */
                }
                return null;
            }
        }

        private UserContext ResolveUser(ErrorContext.ErrorContextValues ctx)
        {
            if (_options.UserProvider != null)
            {
                try
                {
                    var fromProvider = _options.UserProvider();
                    if (fromProvider != null) return fromProvider;
                }
                catch
                {
                    // The identity service is often the thing that is broken.
                    // Fall through to whatever the request context captured.
                }
            }

            if (ctx == null) return null;

            return new UserContext
            {
                Id = ctx.UserId,
                Name = ctx.UserName,
                DisplayName = ctx.UserDisplayName,
                TenantId = ctx.TenantId,
                SessionId = ctx.SessionId,
                ClientIp = ctx.ClientIp
            };
        }

        private static string SafeMachineName()
        {
            try
            {
                return System.Environment.MachineName;
            }
            catch
            {
                return null;
            }
        }

        /// <summary>
        /// Pull just the database name out of a connection string, without
        /// using SqlConnectionStringBuilder on a string that may be malformed -
        /// and without ever surfacing the rest of it.
        /// </summary>
        private static string TryGetDatabaseName(string connectionString)
        {
            if (string.IsNullOrEmpty(connectionString)) return null;
            try
            {
                foreach (var part in connectionString.Split(';'))
                {
                    var eq = part.IndexOf('=');
                    if (eq <= 0) continue;
                    var key = part.Substring(0, eq).Trim();
                    if (key.Equals("Initial Catalog", StringComparison.OrdinalIgnoreCase) ||
                        key.Equals("Database", StringComparison.OrdinalIgnoreCase))
                        return part.Substring(eq + 1).Trim();
                }
            }
            catch
            {
                /* a malformed connection string is not worth an exception here */
            }
            return null;
        }
    }
}
