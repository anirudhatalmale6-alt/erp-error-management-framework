# ERP Error Management Framework

A centralised, dynamic error-handling and incident-management framework for an
ERP built on **Angular 20.3**, **ASP.NET Web API 2 / .NET Framework 4.7.2** and
**SQL Server**, designed to be dropped into a live production system without
restructuring any existing module, page, component, controller or stored
procedure.

```
Error occurs → captured → logged → user notified → user reports
   → ticket created → support queue → investigation → status updates
   → resolution → closure → complete audit trail
```

**Start with [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** — it is the
technical design, and it answers the six points the brief left open
(architecture, packaging, database approach, deduplication, retention,
deployment), plus an honest list of limitations.

---

## What the integration actually costs you

**Angular** — two lines in `app.config.ts`:

```ts
provideHttpClient(withInterceptors([erpHttpErrorInterceptor])),
provideErpErrorManagement({ apiBaseUrl: '/api/error-management', environment: 'Production' }),
```

**Web API 2** — three lines in `WebApiConfig.Register`:

```csharp
config.UseErpErrorManagement(new ErrorCaptureOptions {
    ConnectionString = ConfigurationManager.ConnectionStrings["ErpErrorStore"].ConnectionString,
    Environment      = "Production",
});
```

**SQL Server** — run `db/001` … `db/007` then `db/010` and `db/011` once. Everything lives in its own
`erp_err` schema; no existing object is read, altered or dropped. (`008` and
`009` are optional add-ons — see `docs/ARCHITECTURE.md` §5.3.)

**Legacy NgModule apps** — the same `provideErpErrorManagement(...)` goes in
`AppModule.providers`, plus `ErpLegacyHttpErrorInterceptor` via
`HTTP_INTERCEPTORS` for apps still on `HttpClientModule`. Both styles are
supported side by side.

That is the whole integration surface for existing code. Module and screen names
come from route data (one line per route), not from components.

---

## Repository layout

```
db/                     SQL Server schema, procedures, seed data, retention job
  001_schema_and_config.sql     schema, versioning ledger, all configuration tables
  002_core_tables.sql           fingerprints, occurrences, tickets, audit trail
  003_seed_reference_data.sql   severities, categories, statuses, workflow, SLAs
  004_programmability.sql       usp_Error_Capture and every other procedure
  005_retention_and_archive.sql archive tables + the nightly batched retention job
  006_security.sql              least-privilege grants (EXECUTE only for the app)
  007_end_user_ticket_access.sql "My Tickets" - ownership enforced in SQL
  010_search_performance.sql    server-side sort/keyset paging + indexes
  011_support_access_...sql     support roster/roles, audited assignment,
                                manually raised tickets
  008_optional_...              OPTIONAL: Extended Events for swallowed errors
  009_optional_...              OPTIONAL: one-line capture from a CATCH block

angular/erp-error-workspace/
  projects/erp-error-management/   the reusable Angular library
  projects/demo/                   demo ERP screen + support console + My Tickets
  projects/legacy-ngmodule-check/  a real NgModule app, to prove that path builds

dotnet/
  Erp.ErrorManagement.Core/        netstandard2.0 — shared by BOTH stacks
  Erp.ErrorManagement.WebApi2/     net472 — Web API 2 integration
  Erp.ErrorManagement.AspNetCore/  net8.0 — for future modules
  Erp.ErrorManagement.Tests/       123 verification checks (see below)

demo/api/               runnable demo API (SQLite — a harness, not the product)
docs/ARCHITECTURE.md    the technical design
docs/screenshots/       the flow, captured from the running demo
tools/                  cross-language fingerprint verification
```

---

## Run the verification

```bash
dotnet run --project dotnet/Erp.ErrorManagement.Tests
```

123 checks, covering:

* every T-SQL script parsing against the **real SQL Server 2016 grammar**
  (Microsoft's `ScriptDom` — the parser SSMS and sqlpackage use);
* the C# and TypeScript fingerprints producing **identical hashes** for the same
  fault, so a browser-reported and an API-reported instance of one problem land
  on one row;
* SHA-256 matching `node:crypto` for every input length 0–200;
* redaction keeping what it should and dropping what it should;
* exception classification, including the deadlock → 503 mapping;
* unwrapping of every EF6/EDMX and EF Core exception wrapper;
* the anonymous-capture rate limiter;
* ownership enforcement on the end-user ticket procedures, asserted against
  comment-stripped SQL;
* **the SQL that the dynamic search procedures actually build** — every branch
  combination expanded and parsed, so a syntax error inside a string literal
  cannot reach production;
* support-console authorisation failing **closed**, every admin action carrying
  a capability gate, and the acting user coming from the token rather than the
  request body.

Each group includes a **positive control** — a check that deliberately expects
the negative result — because a suite that cannot fail proves nothing.

```bash
node tools/verify-fingerprint.mjs     # the TypeScript half of the same corpus
```

---

## Run the demo

One command. The only prerequisite is the **.NET 8 SDK** — no Node, no
`npm install`, no second terminal, no database server.

```bash
cd demo/api && dotnet run
# then open http://localhost:5146
curl -X POST http://localhost:5146/api/error-management/demo/seed   # sample history
```

The pre-built Angular bundle is committed under `demo/api/wwwroot` and served by
the same process that hosts the API. **[`demo/README.md`](demo/README.md) is a
guided tour** — what to click, in what order, and what each thing proves.

The **Purchase Order** screen has a button for each error class in the brief:
Angular runtime, unhandled promise, Web API exception, SQL deadlock, stored
procedure error, timeout, connection failure, form validation, LOV failure. None
of the handlers behind those buttons catch anything.

Press **SQL Server deadlock three times** — the message carries a different
process ID each time, so three different strings arrive and collapse to one
problem. That is the deduplication earning its place.

The **Support console** shows recurring problems, full error history, the ticket
queue with its audit trail and metrics, and the cross-layer correlation trail.
**My issues** is the end user's own panel, where they can track and reply to
their own tickets.

`demo/api` is a **demonstration harness**. It re-implements the stored-procedure
logic over SQLite so the framework can be seen working on a laptop. Production
persists through `erp_err.usp_Error_Capture` on SQL Server. The banner at the
top of `demo/api/Program.cs` says the same thing.

---

## The design decisions worth arguing about

Each of these is defended in `docs/ARCHITECTURE.md`; here is the short version.

**An error is not an incident.** One broken LOV produces thousands of
occurrences from dozens of users. Those are one *problem* and at most one
*ticket*. Occurrence → fingerprint → ticket is the backbone of the data model.

**Deduplication is a hash over a normalised signature.** Record ids, GUIDs,
SPIDs, timestamps, file paths, line numbers and bundle hashes are stripped
before hashing — include line numbers and the same bug fingerprints differently
after every release, resetting the counter that justifies a permanent fix. The
signature text is stored next to the hash so an admin can see *why* two errors
were grouped.

**Redaction is an allow-list.** A deny-list is wrong the moment someone adds a
field it has never heard of, and it fails silently. An allow-list fails the
other way: an unclassified field shows as `***` and someone asks for it to be
added.

**ADO.NET, not Entity Framework.** The framework must run under EF6 *and* EF
Core, so it can depend on neither; and the capture path runs when the
application is already in trouble, which is the worst moment to invoke an ORM.

**The database layer is captured by reading `SqlException`.** `Procedure`,
`LineNumber`, `Number` and `Class` are already on it — so stored-procedure
errors are captured with **no changes to any procedure**.

**The support console is protected server-side, per capability.** Every admin
action carries a `[RequiresSupport(...)]` gate and the check fails closed. The
Angular route guard hides a menu item; it is not the boundary. See
`docs/ARCHITECTURE.md` §15.

**Every list is paged, filtered and sorted in SQL.** The browser never receives
more than one page, sorting goes through a whitelist rather than string
concatenation, and the error list also offers keyset paging because `OFFSET`
has to walk and discard every row it skips. See `docs/ARCHITECTURE.md` §14.

**The framework observes; it never changes control flow.** The interceptor
re-throws, the logger does not swallow, and every persistence path ends in a
caught exception with a fallback. If the error store is down, posting a journal
still works.

---

## Status

The framework is complete and verified as described above. Open items are listed in
`docs/ARCHITECTURE.md` §12 — chiefly that the T-SQL has been **parsed** against
the real grammar but not **executed**, because I have no SQL Server instance.
Run `db/001…007`, `db/010` and `db/011` against a development database before production.
