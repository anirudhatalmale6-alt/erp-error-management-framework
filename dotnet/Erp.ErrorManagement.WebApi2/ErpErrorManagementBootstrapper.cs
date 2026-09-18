using System;
using System.Diagnostics;
using System.Web.Http;
using System.Web.Http.Dispatcher;
using System.Web.Http.ExceptionHandling;

namespace Erp.ErrorManagement.WebApi2
{
    /// <summary>
    /// The entire back-end integration, in one call.
    ///
    /// In the existing WebApiConfig.Register(HttpConfiguration config):
    ///
    ///     config.UseErpErrorManagement(new ErrorCaptureOptions
    ///     {
    ///         ConnectionString = ConfigurationManager
    ///             .ConnectionStrings["ErpErrorStore"].ConnectionString,
    ///         Environment      = "Production",
    ///         ApplicationName  = "ERP.Api",
    ///         AppVersion       = typeof(WebApiApplication).Assembly.GetName().Version.ToString(),
    ///         UserProvider     = () => new UserContext { /* your identity */ }
    ///     });
    ///
    /// That is three lines added to one existing file.  No controller, no
    /// service, no repository and no stored procedure is edited.
    /// </summary>
    public static class ErpErrorManagementBootstrapper
    {
        public static HttpConfiguration UseErpErrorManagement(
            this HttpConfiguration config, ErrorCaptureOptions options)
        {
            if (config == null) throw new ArgumentNullException(nameof(config));
            if (options == null) throw new ArgumentNullException(nameof(options));

            options.Validate();

            if (options.FallbackLogger == null)
                options.FallbackLogger = DefaultFallbackLogger;

            var store = new SqlErrorStore(options);
            var capture = new ErrorCaptureService(store, options);

            // Guards the unauthenticated capture endpoint. Constructed once and
            // shared: a per-request instance would have an empty bucket every
            // time, which is the same as no limit at all.
            var throttle = new AnonymousCaptureThrottle(
                options.AnonymousCaptureRatePerMinute,
                options.AnonymousCaptureBurst);

            // Resolves who is support staff, from the ERM roster. Fails
            // CLOSED - if it cannot read the roster, nobody is authorised.
            var directory = new SqlSupportDirectory(options);

            // 1. Ambient context + correlation, before routing.
            config.MessageHandlers.Add(new ErpErrorCorrelationHandler(options.DefaultErpModule));

            // 2. Record every unhandled exception.  ADD, not Replace - Web API
            //    supports multiple loggers and the ERP may already have one
            //    (ELMAH, log4net, Application Insights).  Replacing it would
            //    silently switch off whatever is there today.
            config.Services.Add(typeof(IExceptionLogger), new ErpExceptionLogger(capture));

            // 3. Control what the caller sees.  Replace, not Add - Web API
            //    permits exactly one handler, by design.
            config.Services.Replace(typeof(IExceptionHandler), new ErpExceptionHandler(options));

            // 3a. Gate the support console API. The filter is a no-op for any
            //     action without [RequiresSupport], so adding it cannot affect
            //     a single existing ERP endpoint.
            config.Filters.Add(new ErpAdminAuthorizationFilter(directory, options));

            // 4. Let the framework's own controller be constructed with its
            //    dependencies.  Chains to whatever activator is already
            //    registered, so an existing Unity/Autofac/Ninject container
            //    keeps resolving every other controller exactly as before.
            var existing = config.Services.GetHttpControllerActivator();
            config.Services.Replace(typeof(IHttpControllerActivator),
                new ErpControllerActivator(existing, capture, store, throttle, directory));

            return config;
        }

        private static void DefaultFallbackLogger(string message, Exception exception)
        {
            // Windows Event Log is the right default on IIS: it survives an
            // app-pool recycle, it is already monitored in most shops, and it
            // needs no configuration.  Writing to it can fail if the source was
            // never registered (that needs one elevated command at install
            // time), so Trace is kept underneath it.
            try
            {
                const string source = "ERP Error Management";
                if (EventLog.SourceExists(source))
                {
                    EventLog.WriteEntry(source,
                        message + Environment.NewLine + exception, EventLogEntryType.Error);
                    return;
                }
            }
            catch
            {
                /* fall through to Trace */
            }

            try
            {
                Trace.TraceError("[ERP Error Management] {0}: {1}", message, exception);
            }
            catch
            {
                /* there is genuinely nowhere left */
            }
        }
    }

    /// <summary>
    /// Constructs ErrorManagementController with its dependencies and delegates
    /// everything else to the activator that was already in place.
    ///
    /// This is the least invasive way to inject into a legacy Web API 2 app:
    /// it does not require the host to be using a DI container at all, and it
    /// does not disturb one that is.
    /// </summary>
    internal class ErpControllerActivator : IHttpControllerActivator
    {
        private readonly IHttpControllerActivator _inner;
        private readonly ErrorCaptureService _capture;
        private readonly IErrorStore _store;
        private readonly AnonymousCaptureThrottle _throttle;
        private readonly ISupportDirectory _directory;

        public ErpControllerActivator(IHttpControllerActivator inner,
            ErrorCaptureService capture, IErrorStore store, AnonymousCaptureThrottle throttle,
            ISupportDirectory directory)
        {
            _inner = inner;
            _capture = capture;
            _store = store;
            _throttle = throttle;
            _directory = directory;
        }

        public System.Web.Http.Controllers.IHttpController Create(
            System.Net.Http.HttpRequestMessage request,
            System.Web.Http.Controllers.HttpControllerDescriptor controllerDescriptor,
            Type controllerType)
        {
            if (controllerType == typeof(ErrorManagementController))
                return new ErrorManagementController(_capture, _store, _throttle);

            if (controllerType == typeof(AdminController))
                return new AdminController(_store, _directory);

            if (_inner != null)
                return _inner.Create(request, controllerDescriptor, controllerType);

            return (System.Web.Http.Controllers.IHttpController)Activator.CreateInstance(controllerType);
        }
    }
}
