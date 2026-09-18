using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Http.ExceptionHandling;
using System.Web.Http.Results;

namespace Erp.ErrorManagement.WebApi2
{
    /// <summary>
    /// Web API 2's IExceptionLogger: called for EVERY unhandled exception in the
    /// API, including ones that a filter would never see.
    ///
    /// The difference matters.  An ExceptionFilterAttribute misses exceptions
    /// thrown in:
    ///   - message handlers (including the one above it in the chain),
    ///   - routing and controller selection,
    ///   - model binding and parameter binding,
    ///   - the media-type formatter while WRITING the response,
    ///   - other exception filters.
    /// IExceptionLogger sees all of them.  That is what "capture at any
    /// application layer, without per-controller code" actually requires.
    ///
    /// Registration, once, in WebApiConfig.Register:
    ///
    ///     config.Services.Add(typeof(IExceptionLogger), new ErpExceptionLogger(captureService));
    /// </summary>
    public class ErpExceptionLogger : ExceptionLogger
    {
        private readonly ErrorCaptureService _capture;

        public ErpExceptionLogger(ErrorCaptureService capture)
        {
            _capture = capture ?? throw new ArgumentNullException(nameof(capture));
        }

        public override async Task LogAsync(ExceptionLoggerContext context, CancellationToken cancellationToken)
        {
            try
            {
                var request = context?.Request;
                var path = request?.RequestUri?.AbsolutePath;

                if (context?.Exception == null || _capture.ShouldIgnore(context.Exception, path)) return;

                EnrichContextFromActionContext(context);

                var result = await _capture.CaptureAsync(
                    context.Exception,
                    "webapi2",
                    requestHeaders: ReadHeaders(request),
                    queryString: ReadQuery(request),
                    customData: BuildCustomData(context),
                    ct: cancellationToken).ConfigureAwait(false);

                // Stash the reference so ErpExceptionHandler can put it in the
                // response body.  Request.Properties is per-request and is the
                // only channel the two components share.
                if (result?.ErrorReference != null && request != null)
                {
                    request.Properties[ErrorReferenceKey] = result.ErrorReference;
                    request.Properties[CaptureResultKey] = result;
                }
            }
            catch
            {
                // An exception logger that throws replaces the original
                // exception with its own - the single most effective way to
                // make a production incident undiagnosable.
            }
        }

        public const string ErrorReferenceKey = "ERM.ErrorReference";
        public const string CaptureResultKey = "ERM.CaptureResult";

        /// <summary>
        /// Fill in the controller and action, which the message handler could
        /// not know because routing had not run yet when it fired.
        /// </summary>
        private static void EnrichContextFromActionContext(ExceptionLoggerContext context)
        {
            ErrorContext.Enrich(values =>
            {
                var descriptor = context.CatchBlock?.Name;
                var actionContext = context.ExceptionContext?.ActionContext;

                if (actionContext?.ActionDescriptor != null)
                {
                    values.ApiAction = actionContext.ActionDescriptor.ActionName;
                    values.ApiController = actionContext.ActionDescriptor.ControllerDescriptor?.ControllerName;
                }
                else if (context.ExceptionContext?.ControllerContext?.ControllerDescriptor != null)
                {
                    values.ApiController = context.ExceptionContext.ControllerContext.ControllerDescriptor.ControllerName;
                }

                if (values.ApiEndpoint == null)
                    values.ApiEndpoint = context.Request?.RequestUri?.AbsolutePath;

                // The catch block name tells you WHERE in the pipeline it blew
                // up - 'HttpControllerDispatcher' vs 'HttpServer' vs
                // 'IExceptionFilter'.  Cheap, and it saves an hour of guessing.
                if (!string.IsNullOrEmpty(descriptor) && string.IsNullOrEmpty(values.Screen))
                    values.Screen = values.Screen; // left as-is; catch block goes to CustomData
            });
        }

        private static Dictionary<string, object> BuildCustomData(ExceptionLoggerContext context)
        {
            return new Dictionary<string, object>
            {
                ["catchBlock"] = context.CatchBlock?.Name,
                ["isTopLevel"] = context.CatchBlock?.IsTopLevel,
                ["requestContextVirtualPathRoot"] = context.RequestContext?.VirtualPathRoot
            };
        }

        private static Dictionary<string, string> ReadHeaders(HttpRequestMessage request)
        {
            if (request == null) return null;
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                foreach (var header in request.Headers)
                    result[header.Key] = string.Join(", ", header.Value);
                if (request.Content != null)
                    foreach (var header in request.Content.Headers)
                        result[header.Key] = string.Join(", ", header.Value);
            }
            catch
            {
                /* a malformed header collection is not worth losing the error over */
            }
            return result;
        }

        private static Dictionary<string, string> ReadQuery(HttpRequestMessage request)
        {
            if (request?.RequestUri == null) return null;
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                foreach (var pair in request.GetQueryNameValuePairs())
                    result[pair.Key] = pair.Value;
            }
            catch
            {
                /* an unparseable query string is not worth losing the error over */
            }
            return result;
        }
    }

    /// <summary>
    /// Web API 2's IExceptionHandler: decides what the CALLER sees.
    ///
    /// The logger above records the truth; this returns the sanitised version.
    /// The two are separate interfaces in Web API 2 for exactly this reason, and
    /// it maps precisely onto the brief's requirement that the user gets a
    /// professional message and a reference number while the stack trace,
    /// SQL error and server details go only to the error store.
    ///
    /// Registration, once, in WebApiConfig.Register:
    ///
    ///     config.Services.Replace(typeof(IExceptionHandler), new ErpExceptionHandler(options));
    /// </summary>
    public class ErpExceptionHandler : ExceptionHandler
    {
        private readonly ErrorCaptureOptions _options;

        public ErpExceptionHandler(ErrorCaptureOptions options)
        {
            _options = options ?? throw new ArgumentNullException(nameof(options));
        }

        /// <summary>
        /// Only handle what is safe to handle.  Web API asks this first; saying
        /// "yes" to a request that cannot buffer its content (a streamed
        /// download that failed mid-write) produces a worse failure than the
        /// original.
        /// </summary>
        public override bool ShouldHandle(ExceptionHandlerContext context)
        {
            return context?.CatchBlock?.IsTopLevel == true;
        }

        public override void Handle(ExceptionHandlerContext context)
        {
            try
            {
                var request = context.Request;

                string errorReference = null;
                if (request != null &&
                    request.Properties.TryGetValue(ErpExceptionLogger.ErrorReferenceKey, out var stored))
                {
                    errorReference = stored as string;
                }

                var classification = ExceptionClassifier.Classify(context.Exception);
                var status = MapStatus(classification.HttpStatusCode);

                var body = _options.UserFacingResponseFactory != null
                    ? _options.UserFacingResponseFactory(errorReference)
                    : new { message = "An unexpected error occurred.", errorReference };

                var response = request != null
                    ? request.CreateResponse(status, body)
                    : new HttpResponseMessage(status);

                // Also on a header, so a client that cannot parse the body -
                // a file download, an old jQuery call - can still surface it.
                if (errorReference != null)
                    response.Headers.TryAddWithoutValidation("X-Error-Reference", errorReference);

                context.Result = new ResponseMessageResult(response);
            }
            catch
            {
                // Falling through leaves Web API's own default handler in
                // charge, which returns a bare 500.  Unhelpful, but correct -
                // and infinitely better than an exception inside the exception
                // handler, which IIS turns into a raw YSOD.
            }
        }

        private static HttpStatusCode MapStatus(int code)
        {
            // 499 is nginx's "client closed request" - not a real HTTP status,
            // and Web API will not serialise it.  Nothing is listening anyway.
            if (code == 499) return HttpStatusCode.InternalServerError;
            return Enum.IsDefined(typeof(HttpStatusCode), code)
                ? (HttpStatusCode)code
                : HttpStatusCode.InternalServerError;
        }
    }
}
