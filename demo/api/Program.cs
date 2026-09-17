// =============================================================================
//  ERP Error Management Framework - RUNNABLE DEMO API
// =============================================================================
//
//  READ THIS FIRST.
//
//  This project exists so the framework can be SEEN working end to end on a
//  laptop with nothing installed but the .NET SDK.  It is a demonstration
//  harness, not the production path.
//
//  What is real here:
//    - the envelope contract, byte for byte
//    - the fingerprinting, redaction and classification (it references the same
//      Erp.ErrorManagement.Core assembly the production packages use)
//    - the deduplication behaviour, the ticket lifecycle, the transition
//      validation, the audit trail and the SLA/elapsed metrics
//
//  What is NOT real here:
//    - the storage.  Production persists through erp_err.usp_Error_Capture on
//      SQL Server (db/004_programmability.sql).  This demo re-implements the
//      same logic over SQLite so it needs no database server.  The SQLite code
//      below is a MIRROR of the T-SQL, not a substitute for it - the T-SQL is
//      the deliverable and is verified separately by the ScriptDom parse in
//      Erp.ErrorManagement.Tests.
//
//  In the real ERP, this whole file is replaced by three lines in
//  WebApiConfig.Register - see dotnet/Erp.ErrorManagement.WebApi2.
// =============================================================================

using System.Text.Json;
using System.Text.Json.Serialization;
using Erp.ErrorManagement;
using Microsoft.Data.Sqlite;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddCors(o => o.AddDefaultPolicy(p => p
    .AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod()
    .WithExposedHeaders("X-Correlation-Id", "X-Error-Reference")));

var dbPath = Path.Combine(AppContext.BaseDirectory, "demo-error-store.db");
var connectionString = $"Data Source={dbPath}";
var store = new DemoStore(connectionString);
store.Initialise();

builder.Services.AddSingleton(store);

var app = builder.Build();
app.UseCors();

// ---------------------------------------------------------------------------
//  Serve the built Angular demo from this same process.
//
//  The demo used to need two terminals and the Node toolchain. It now needs
//  neither: the pre-built Angular bundle is committed under demo/wwwroot and
//  served from here, so the whole thing is `dotnet run` and one URL. Anyone
//  with the .NET 8 SDK can see it, which is the point of a demo.
//
//  This is demo-harness plumbing only. In the real ERP, IIS serves your
//  Angular app exactly as it does today and the framework adds nothing to that
//  path - see dotnet/Erp.ErrorManagement.WebApi2.
// ---------------------------------------------------------------------------
// wwwroot under the project, which is where ASP.NET expects it - the built
// Angular bundle is committed there so `dotnet run` serves it directly.
var webRoot = Path.Combine(builder.Environment.ContentRootPath, "wwwroot");
var hasUi = File.Exists(Path.Combine(webRoot, "index.html"));

if (hasUi)
{
    app.UseDefaultFiles();
    app.UseStaticFiles();
}

var json = new JsonSerializerOptions
{
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
};

// ---------------------------------------------------------------- capture ---
app.MapPost("/api/error-management/errors", async (HttpContext ctx, DemoStore db) =>
{
    var envelopes = await JsonSerializer.DeserializeAsync<List<ErrorEnvelope>>(
        ctx.Request.Body, json) ?? new List<ErrorEnvelope>();

    var clientIp = ctx.Connection.RemoteIpAddress?.ToString();
    var results = new List<ErrorCaptureResult>();

    foreach (var envelope in envelopes.Take(50))
    {
        // Server-side re-scrub: the store never trusts the sender.
        envelope.Message = Redactor.ScrubText(envelope.Message, 2000);
        envelope.StackTrace = Redactor.ScrubText(envelope.StackTrace, 20000);
        if (envelope.User is not null) envelope.User.ClientIp = clientIp;

        results.Add(db.Capture(envelope) ?? new ErrorCaptureResult { ShouldNotifyUser = true });
    }

    return Results.Json(results, json);
});

app.MapPost("/api/error-management/errors/beacon", async (HttpContext ctx, DemoStore db) =>
{
    var envelopes = await JsonSerializer.DeserializeAsync<List<ErrorEnvelope>>(
        ctx.Request.Body, json) ?? new List<ErrorEnvelope>();
    foreach (var e in envelopes.Take(50)) db.Capture(e);
    return Results.NoContent();
});

// ----------------------------------------------------------------- tickets --
app.MapPost("/api/error-management/tickets", async (HttpContext ctx, DemoStore db) =>
{
    var req = await JsonSerializer.DeserializeAsync<TicketRequest>(ctx.Request.Body, json);
    if (req?.ErrorReference is null) return Results.BadRequest(new { message = "errorReference is required" });

    var user = ctx.Request.Headers["X-Demo-User"].FirstOrDefault() ?? "fatima.saeed";
    var result = db.CreateTicket(req.ErrorReference, req.UserDescription, user, "user");
    return result is null
        ? Results.Json(new { message = "Ticket could not be created." }, json, statusCode: 503)
        : Results.Json(result, json);
});

app.MapGet("/api/error-management/tickets", (DemoStore db, string? status, bool? onlyOpen)
    => Results.Json(db.SearchTickets(status, onlyOpen), json));

app.MapGet("/api/error-management/tickets/{ticketNumber}", (DemoStore db, string ticketNumber)
    => Results.Json(db.GetTicket(ticketNumber), json));

// ---- end-user "My Tickets" -------------------------------------------------
// The demo stands in for JWT with an X-Demo-User header. In production the
// identity comes from the validated token and NEVER from a request parameter -
// that is the whole point, so the demo does not accept one either.
static string DemoUser(HttpContext ctx)
    => ctx.Request.Headers["X-Demo-User"].FirstOrDefault() ?? "fatima.saeed";

app.MapGet("/api/error-management/tickets/mine", (HttpContext ctx, DemoStore db, bool onlyOpen = false)
    => Results.Json(db.ListTicketsForUser(DemoUser(ctx), onlyOpen), json));

app.MapGet("/api/error-management/my-tickets/{ticketNumber}", (HttpContext ctx, DemoStore db, string ticketNumber) =>
{
    var detail = db.GetTicketForUser(ticketNumber, DemoUser(ctx));
    // 404 for "not yours" as well as "not there": a 403 would confirm the
    // number is real and turn sequential numbers into an enumeration oracle.
    return detail is null ? Results.NotFound() : Results.Json(detail, json);
});

app.MapPost("/api/error-management/my-tickets/{ticketNumber}/comments",
    async (HttpContext ctx, DemoStore db, string ticketNumber) =>
{
    var req = await JsonSerializer.DeserializeAsync<CommentRequest>(ctx.Request.Body, json);
    if (string.IsNullOrWhiteSpace(req?.CommentText))
        return Results.BadRequest(new { message = "commentText is required" });

    var ok = db.AddUserComment(ticketNumber, DemoUser(ctx), req!.CommentText!);
    return ok ? Results.Json(new { added = true }, json) : Results.NotFound();
});

app.MapPost("/api/error-management/tickets/{ticketNumber}/status",
    async (HttpContext ctx, DemoStore db, string ticketNumber) =>
{
    var req = await JsonSerializer.DeserializeAsync<StatusChangeRequest>(ctx.Request.Body, json);
    if (req is null) return Results.BadRequest();
    var user = ctx.Request.Headers["X-Demo-User"].FirstOrDefault() ?? "sam.ops";
    try
    {
        return Results.Json(db.ChangeStatus(ticketNumber, req.ToStatus!, user, req.Comments,
            req.AssignTo), json);
    }
    catch (InvalidOperationException ex)
    {
        return Results.Json(new { message = ex.Message }, json, statusCode: 400);
    }
});

// --------------------------------------------------------------- admin/read --
// Filtering, sorting and paging are all query parameters handled server-side.
// The browser never receives more than one page.
app.MapGet("/api/error-management/admin/errors", (
        DemoStore db,
        string? severity, string? layer, string? category, string? erpModule,
        string? userName, string? correlationId, string? searchText,
        string? fromUtc, string? toUtc, bool? onlyUnticketed,
        string? sortBy, int pageNumber = 1, int pageSize = 25)
    => Results.Json(db.SearchErrors(new ErrorQuery
    {
        Severity = severity, Layer = layer, Category = category, ErpModule = erpModule,
        UserName = userName, CorrelationId = correlationId, SearchText = searchText,
        FromUtc = fromUtc, ToUtc = toUtc, OnlyUnticketed = onlyUnticketed,
        SortBy = sortBy, PageNumber = pageNumber, PageSize = pageSize
    }), json));

app.MapGet("/api/error-management/admin/problems", (
        DemoStore db,
        string? severity, string? layer, string? erpModule, bool? includeMuted,
        string? fromUtc, int minOccurrences = 1,
        string? sortBy = null, int pageNumber = 1, int pageSize = 25)
    => Results.Json(db.RecurringProblems(new ProblemQuery
    {
        Severity = severity, Layer = layer, ErpModule = erpModule,
        IncludeMuted = includeMuted, FromUtc = fromUtc,
        MinOccurrences = minOccurrences,
        SortBy = sortBy, PageNumber = pageNumber, PageSize = pageSize
    }), json));

app.MapGet("/api/error-management/admin/dashboard", (DemoStore db)
    => Results.Json(db.Dashboard(), json));

app.MapGet("/api/error-management/admin/correlation/{correlationId}", (DemoStore db, string correlationId)
    => Results.Json(db.CorrelationTrail(correlationId), json));

app.MapGet("/api/error-management/admin/error/{errorReference}", (DemoStore db, string errorReference)
    => Results.Json(db.GetErrorDetail(errorReference), json));

// --------------------------------------------- deliberately failing endpoints
// These exist so the demo UI can prove capture of API-, business- and
// database-layer faults, not just browser ones.
app.MapGet("/api/demo/server-error", (DemoStore db, HttpContext ctx) =>
{
    var envelope = db.BuildServerEnvelope(
        ctx,
        layer: ErrorLayers.WebApi,
        category: ErrorCategories.ApiUnhandled,
        severity: ErrorSeverities.Critical,
        exceptionType: "System.NullReferenceException",
        message: "Object reference not set to an instance of an object.",
        stack: "   at Erp.Purchasing.PurchaseOrderService.Recalculate(Int32 orderId) in C:\\build\\src\\PurchaseOrderService.cs:line 214\n   at Erp.Api.Controllers.PurchaseOrderController.Post(PurchaseOrderDto dto)",
        controller: "PurchaseOrder", action: "Post");
    var result = db.Capture(envelope);
    return Results.Json(new { message = "We encountered an unexpected problem while processing your request.", errorReference = result?.ErrorReference }, json, statusCode: 500);
});

app.MapGet("/api/demo/sql-deadlock", (DemoStore db, HttpContext ctx) =>
{
    var spid = Random.Shared.Next(50, 200);
    var envelope = db.BuildServerEnvelope(
        ctx,
        layer: ErrorLayers.Database,
        category: ErrorCategories.SqlDeadlock,
        severity: ErrorSeverities.High,
        exceptionType: "System.Data.SqlClient.SqlException",
        // The SPID changes on every call - which is exactly the case
        // normalisation has to absorb, or every deadlock is a new "problem".
        message: $"Transaction (Process ID {spid}) was deadlocked on lock resources with another process and has been chosen as the deadlock victim. Rerun the transaction.",
        stack: "   at System.Data.SqlClient.SqlCommand.ExecuteNonQuery()\n   at Erp.Finance.JournalRepository.Post(Journal j) in C:\\build\\src\\JournalRepository.cs:line 88",
        controller: "Journal", action: "Post",
        sql: new SqlErrorInfo
        {
            Number = 1205, Severity = 13, State = 51,
            ObjectName = "usp_PostJournal", LineNumber = 142,
            ServerName = "ERP-SQL01", DatabaseName = "ERP_PROD", SchemaName = "fin"
        });
    var result = db.Capture(envelope);
    return Results.Json(new { message = "We encountered an unexpected problem while processing your request.", errorReference = result?.ErrorReference }, json, statusCode: 503);
});

app.MapGet("/api/demo/lov-failure", (DemoStore db, HttpContext ctx) =>
{
    var envelope = db.BuildServerEnvelope(
        ctx,
        layer: ErrorLayers.Database,
        category: ErrorCategories.SqlProcedure,
        severity: ErrorSeverities.Medium,
        exceptionType: "System.Data.SqlClient.SqlException",
        message: "Invalid column name 'IsActiveFlag'.",
        stack: "   at Erp.Common.LovRepository.Load(String lovCode) in C:\\build\\src\\LovRepository.cs:line 41",
        controller: "Lov", action: "Get",
        sql: new SqlErrorInfo
        {
            Number = 207, Severity = 16, State = 1,
            ObjectName = "usp_GetCostCentreLov", LineNumber = 12,
            ServerName = "ERP-SQL01", DatabaseName = "ERP_PROD", SchemaName = "common"
        });
    var result = db.Capture(envelope);
    return Results.Json(new { message = "The list of values could not be loaded.", errorReference = result?.ErrorReference }, json, statusCode: 500);
});

app.MapGet("/api/demo/slow-timeout", () => Results.Json(new { message = "gateway timeout" }, json, statusCode: 504));
app.MapGet("/api/demo/ok", () => Results.Json(new { ok = true, at = DateTime.UtcNow }, json));

app.MapPost("/api/error-management/demo/reset", (DemoStore db) => { db.Reset(); return Results.Ok(new { reset = true }); });
app.MapPost("/api/error-management/demo/seed", (DemoStore db) => { db.Seed(); return Results.Ok(new { seeded = true }); });

// SPA fallback, registered LAST so it can never shadow an /api route: the
// Angular router owns /purchase-order, /admin and /my-issues, and a hard
// refresh on any of them must return index.html rather than 404.
if (hasUi)
{
    app.MapFallback(async ctx =>
    {
        if (ctx.Request.Path.StartsWithSegments("/api"))
        {
            ctx.Response.StatusCode = StatusCodes.Status404NotFound;
            return;
        }
        ctx.Response.ContentType = "text/html";
        await ctx.Response.SendFileAsync(Path.Combine(webRoot, "index.html"));
    });
}

Console.WriteLine();
Console.WriteLine("  ERP Error Management Framework - demo");
Console.WriteLine(hasUi
    ? "  Open http://localhost:5146  (the UI is served from this process)"
    : "  API only - demo/wwwroot not found, so no UI is being served.");
Console.WriteLine("  Sample data:  POST http://localhost:5146/api/error-management/demo/seed");
Console.WriteLine();

app.Run();

record TicketRequest(string? ErrorReference, string? UserDescription);
record StatusChangeRequest(string? ToStatus, string? Comments, string? AssignTo);
record CommentRequest(string? CommentText);
