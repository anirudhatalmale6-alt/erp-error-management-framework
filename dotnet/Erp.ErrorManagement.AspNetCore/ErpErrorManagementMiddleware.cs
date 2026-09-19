using System.Security.Claims;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;

namespace Erp.ErrorManagement.AspNetCore;

/// <summary>
/// One middleware doing both jobs the Web API 2 side splits across a message
/// handler and two service interfaces: open the ambient context on the way in,
/// capture and sanitise on the way out.
/// </summary>
public class ErpErrorManagementMiddleware
{
    public const string CorrelationHeader = "X-Correlation-Id";
    public const string RequestHeader = "X-Request-Id";
    public const string ModuleHeader = "X-Erp-Module";
    public const string ScreenHeader = "X-Erp-Screen";
    public const string AppVersionHeader = "X-App-Version";

    private readonly RequestDelegate _next;
    private readonly ErrorCaptureService _capture;
    private readonly ErrorCaptureOptions _options;
    private readonly ILogger<ErpErrorManagementMiddleware> _logger;

    public ErpErrorManagementMiddleware(
        RequestDelegate next,
        ErrorCaptureService capture,
        ErrorCaptureOptions options,
        ILogger<ErpErrorManagementMiddleware> logger)
    {
        _next = next;
        _capture = capture;
        _options = options;
        _logger = logger;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        var values = new ErrorContext.ErrorContextValues
        {
            CorrelationId = ReadGuid(context, CorrelationHeader) ?? Guid.NewGuid(),
            RequestId = ReadGuid(context, RequestHeader) ?? Guid.NewGuid(),
            ErpModule = ReadHeader(context, ModuleHeader) ?? _options.DefaultErpModule,
            Screen = ReadHeader(context, ScreenHeader),
            AppVersion = ReadHeader(context, AppVersionHeader) ?? _options.AppVersion,
            HttpMethod = context.Request.Method,
            ApiEndpoint = context.Request.Path.Value,
            ClientIp = context.Connection.RemoteIpAddress?.ToString(),
            SessionId = context.TraceIdentifier,
            StartedUtc = DateTime.UtcNow
        };

        ApplyIdentity(context.User, values);
        ErrorContext.Begin(values);

        // Set the response header now, while the response has not started -
        // after the first byte is written, adding a header silently does
        // nothing, which is a confusing way to lose your correlation id.
        context.Response.OnStarting(() =>
        {
            if (!context.Response.Headers.ContainsKey(CorrelationHeader))
                context.Response.Headers[CorrelationHeader] = values.CorrelationId.ToString();
            return Task.CompletedTask;
        });

        try
        {
            await _next(context);
        }
        catch (Exception ex)
        {
            var path = context.Request.Path.Value;

            if (_capture.ShouldIgnore(ex, path))
                throw;

            EnrichFromEndpoint(context);

            ErrorCaptureResult? result = null;
            try
            {
                result = await _capture.CaptureAsync(
                    ex,
                    "aspnetcore",
                    requestHeaders: context.Request.Headers.ToDictionary(
                        h => h.Key, h => h.Value.ToString()),
                    queryString: context.Request.Query.ToDictionary(
                        q => q.Key, q => q.Value.ToString()),
                    ct: context.RequestAborted);
            }
            catch (Exception captureFailure)
            {
                _logger.LogError(captureFailure, "ERP error capture failed while handling {Path}", path);
            }

            // If the response has already started there is nothing safe to do
            // but let it fail - rewriting a partially-sent response corrupts it.
            if (context.Response.HasStarted) throw;

            context.Response.Clear();
            context.Response.StatusCode = ExceptionClassifier.Classify(ex).HttpStatusCode is var code
                && code is >= 400 and < 600 ? code : StatusCodes.Status500InternalServerError;
            context.Response.ContentType = "application/json";

            if (result?.ErrorReference is not null)
                context.Response.Headers["X-Error-Reference"] = result.ErrorReference;

            var body = _options.UserFacingResponseFactory is not null
                ? _options.UserFacingResponseFactory(result?.ErrorReference)
                : new { message = "An unexpected error occurred.", errorReference = result?.ErrorReference };

            await context.Response.WriteAsJsonAsync(body, context.RequestAborted);
        }
        finally
        {
            ErrorContext.End();
        }
    }

    private static void EnrichFromEndpoint(HttpContext context)
    {
        ErrorContext.Enrich(values =>
        {
            var endpoint = context.GetEndpoint();
            var descriptor = endpoint?.Metadata
                .GetMetadata<Microsoft.AspNetCore.Mvc.Controllers.ControllerActionDescriptor>();

            if (descriptor is not null)
            {
                values.ApiController = descriptor.ControllerName;
                values.ApiAction = descriptor.ActionName;
            }
            else if (endpoint?.DisplayName is not null)
            {
                // Minimal APIs have no controller/action - the endpoint display
                // name is the only identity they have, and it is still useful.
                values.ApiAction = endpoint.DisplayName;
            }
        });
    }

    private static void ApplyIdentity(ClaimsPrincipal? principal, ErrorContext.ErrorContextValues values)
    {
        try
        {
            if (principal?.Identity?.IsAuthenticated != true) return;

            values.UserName = principal.Identity.Name;

            // Same rule as the Web API 2 side: the ERP UserProfileID is an
            // integer and anything that is not a positive integer means "no
            // user", not "user 0".
            foreach (var claimType in new[] { "UserProfileID", "userProfileId", "uid", "sub" })
            {
                var raw = principal.FindFirst(claimType)?.Value;
                if (int.TryParse(raw, out var parsed) && ErpUser.IsReal(parsed))
                {
                    values.UserProfileId = parsed;
                    break;
                }
            }
            values.UserDisplayName = principal.FindFirst("name")?.Value ?? principal.Identity.Name;
            values.TenantId = principal.FindFirst("tid")?.Value
                              ?? principal.FindFirst("tenantId")?.Value;
        }
        catch
        {
            // Identity resolution is best-effort; an anonymous record beats none.
        }
    }

    private static string? ReadHeader(HttpContext context, string name)
    {
        if (!context.Request.Headers.TryGetValue(name, out var value)) return null;
        var s = value.ToString();
        if (string.IsNullOrWhiteSpace(s)) return null;
        return s.Length > 200 ? s[..200] : s;
    }

    private static Guid? ReadGuid(HttpContext context, string name)
        => Guid.TryParse(ReadHeader(context, name), out var g) ? g : null;
}

public static class ErpErrorManagementExtensions
{
    /// <summary>
    /// In Program.cs:
    ///
    ///     builder.Services.AddErpErrorManagement(options =>
    ///     {
    ///         options.ConnectionString = builder.Configuration.GetConnectionString("ErpErrorStore")!;
    ///         options.Environment      = builder.Environment.EnvironmentName;
    ///         options.ApplicationName  = "ERP.Procurement";
    ///     });
    ///     ...
    ///     app.UseErpErrorManagement();   // first, so it wraps everything below it
    /// </summary>
    public static IServiceCollection AddErpErrorManagement(
        this IServiceCollection services, Action<ErrorCaptureOptions> configure)
    {
        var options = new ErrorCaptureOptions();
        configure(options);
        options.Validate();

        services.TryAddSingleton(options);
        services.TryAddSingleton<IErrorStore>(_ => new SqlErrorStore(options));
        services.TryAddSingleton(sp => new ErrorCaptureService(
            sp.GetRequiredService<IErrorStore>(), options));

        // Route the store's own failures into the host's logging, rather than
        // leaving them in a silent catch.
        services.AddSingleton<IConfigureErpFallbackLogger, ConfigureErpFallbackLogger>();
        return services;
    }

    public static IApplicationBuilder UseErpErrorManagement(this IApplicationBuilder app)
    {
        // Resolving this here wires the fallback logger exactly once, at the
        // point the DI container is guaranteed to be built.
        app.ApplicationServices.GetService<IConfigureErpFallbackLogger>()?.Configure();
        return app.UseMiddleware<ErpErrorManagementMiddleware>();
    }
}

public interface IConfigureErpFallbackLogger
{
    void Configure();
}

internal sealed class ConfigureErpFallbackLogger : IConfigureErpFallbackLogger
{
    private readonly ErrorCaptureOptions _options;
    private readonly ILoggerFactory _loggerFactory;

    public ConfigureErpFallbackLogger(ErrorCaptureOptions options, ILoggerFactory loggerFactory)
    {
        _options = options;
        _loggerFactory = loggerFactory;
    }

    public void Configure()
    {
        _options.FallbackLogger ??= (message, ex) =>
            _loggerFactory.CreateLogger("Erp.ErrorManagement").LogError(ex, "{Message}", message);
    }
}
