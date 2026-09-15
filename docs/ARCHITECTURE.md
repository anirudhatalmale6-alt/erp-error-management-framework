# ERP Error Management Framework — Technical Design

Version 1.0.0 · 15 September 2026

This document answers the six points the brief explicitly left to the
freelancer to propose:

| # | The brief asks | Section |
|---|---|---|
| 1 | Technical architecture and library/package structure | §2, §3 |
| 2 | Integration mechanism for Angular 20, Web API 2 / .NET 4.7.2, and .NET 8 / EF Core | §4 |
| 3 | Database architecture, and Code First vs Database First | §5 |
| 4 | Deduplication / recurring-error approach | §6 |
| 5 | Data retention and archiving mechanism | §7 |
| 6 | Deployment approach | §9 |

Everything described here is implemented in this repository, not just proposed.
§11 lists what is verified and how, and §12 lists the limitations honestly.

---

## 1. The shape of the problem

The brief asks for eleven classes of error to be captured across four layers
with no per-page code. Those eleven classes are not one problem — they are
three, and they need three different mechanisms:

1. **Things that throw.** Angular runtime errors, .NET exceptions, SQL errors.
   These have a global interception point per runtime, and can be captured with
   zero changes to existing code.
2. **Things that fail without throwing.** A form that fails validation, a LOV
   that returns nothing, a submit button that is refused by a business rule.
   Nothing throws, so there is nothing for a global handler to catch. These need
   one call at one place — see §4.4, where I am explicit about the trade-off.
3. **Things that throw somewhere nobody is listening.** An unawaited promise, a
   callback outside the Angular zone, an error inside a `setTimeout`. These need
   window-level listeners, not the framework's error handler.

A design that only solves (1) will look complete in a demo and leave gaps in
production. All three are handled; where a mechanism cannot be fully automatic,
that is stated rather than glossed over.

The second structural observation is that **an error is not an incident**. One
broken LOV produces thousands of occurrences from dozens of users; those are one
problem and should be at most one ticket. That distinction — occurrence,
problem (fingerprint), ticket — is the backbone of the whole data model, and it
is what §6 is about.

---

## 2. Architecture

```
  Browser                        API                           SQL Server
  ─────────────────────────      ─────────────────────────     ────────────────────
  Angular 20 ERP                 ASP.NET Web API 2             ERP schemas
   │                             (.NET Framework 4.7.2)         (untouched)
   │  @erp/error-management       │                             │
   │   ├ ErrorHandler             │ Erp.ErrorManagement.WebApi2 │
   │   ├ HTTP interceptor  ──────►│  ├ correlation handler      │
   │   ├ window listeners         │  ├ IExceptionLogger         │
   │   ├ form/LOV helper          │  └ IExceptionHandler        │
   │   ├ fingerprint (TS)         │        │                    │
   │   ├ redaction (allow-list)   │  Erp.ErrorManagement.Core   │
   │   ├ offline queue + beacon   │   ├ fingerprint (C#)  ──────┼──►  erp_err schema
   │   └ dialog + ticket flow     │   ├ redaction               │      ├ tables
   │                              │   ├ classifier              │      ├ procedures
   └──────────────────────────────┘   └ SqlErrorStore  ─────────┼──►   └ retention job
                                  │                             │
   Future modules ────────────────┤ Erp.ErrorManagement         │
   (.NET 8 + EF Core)             │        .AspNetCore          │
                                  │  └ middleware               │
```

Three principles drive every decision below.

**The framework observes; it never changes control flow.** The HTTP interceptor
re-throws. The exception logger does not swallow. A screen that already handles
its own 404 keeps handling it exactly as it did before the framework was
installed. This is what makes the rollout safe on a production ERP.

**The framework can fail without the ERP noticing.** Every persistence path
ends in a swallowed exception with a fallback log. If SQL Server is down, the
error store is down — and posting a journal still works. A logging framework
that can take down the application it logs for is worse than no logging.

**One capture funnel.** Browser, API and database errors all end up in the same
`ErrorEnvelope` shape, hashed by the same algorithm, redacted by the same
allow-list, and written by the same stored procedure. Two capture paths mean
two behaviours, and eventually two definitions of "the same error".

---

## 3. Packages

| Package | Target | Consumed by |
|---|---|---|
| `@erp/error-management` (npm) | Angular 20.x | The ERP front end and every future Angular library/module |
| `Erp.ErrorManagement.Core` | **netstandard2.0** | Both .NET packages below |
| `Erp.ErrorManagement.WebApi2` | net472 | The existing Web API 2 application |
| `Erp.ErrorManagement.AspNetCore` | net8.0 | New .NET 8 modules |

The `netstandard2.0` target for Core is the single most important packaging
decision. It is the only target consumable by **both** .NET Framework 4.7.2 and
.NET 8, which means the fingerprinting, redaction, classification and envelope
contract exist once in the codebase rather than twice. Two copies would drift,
and the day they drift is the day one fault starts opening two tickets.

Publish all four to an internal feed (Azure Artifacts, a private npm registry,
or a file-share NuGet source). A consuming module then takes a version
dependency, not a source copy.

### 3.1 The one thing implemented twice

`Fingerprint` exists in TypeScript and in C#, because the browser has no .NET
and the API has no JavaScript. That duplication is unavoidable, so it is
covered by a test rather than by hope: `Erp.ErrorManagement.Tests` asserts that
the C# implementation produces the **exact hash** the TypeScript implementation
produces for a shared corpus, including the sort order of validation keys
(ordinal, to match JavaScript's `Array.sort`, which is not .NET's default). If
the two ever diverge, the build fails.

---

## 4. Integration

### 4.1 Angular — two lines in `app.config.ts`

```ts
providers: [
  provideHttpClient(withInterceptors([erpHttpErrorInterceptor])),
  provideErpErrorManagement({
    apiBaseUrl: '/api/error-management',
    environment: 'Production',
    appVersion: '2026.3.1',
    userProvider: () => authService.currentUser,
  }),
]
```

That is the entire front-end change. It installs:

* a replacement `ErrorHandler` — catches every uncaught exception in every
  component, pipe, guard, resolver and rxjs subscription in the application;
* an HTTP interceptor — captures every failed call and stamps the correlation
  headers;
* `window.onerror` and `unhandledrejection` listeners — cover what Angular's
  handler cannot see;
* a passive click listener that builds the breadcrumb trail.

**Module and screen come from route data**, not from components:

```ts
{ path: 'purchase-order', loadComponent: …,
  data: { erpErrorContext: { module: 'MM', screen: 'Purchase Order Entry' } } }
```

One line per route, in a file the ERP already maintains. Every error raised
anywhere under that route is stamped automatically.

For an `NgModule` application the same providers go in `AppModule.providers` —
`makeEnvironmentProviders` is accepted there too.

### 4.2 Web API 2 — three lines in `WebApiConfig.Register`

```csharp
config.UseErpErrorManagement(new ErrorCaptureOptions
{
    ConnectionString = ConfigurationManager.ConnectionStrings["ErpErrorStore"].ConnectionString,
    Environment      = "Production",
    ApplicationName  = "ERP.Api",
});
```

This registers a `DelegatingHandler` (ambient context + correlation, before
routing), an `IExceptionLogger` (records everything) and an `IExceptionHandler`
(controls what the caller sees).

`IExceptionLogger` rather than an `ExceptionFilterAttribute` is deliberate. A
filter never sees exceptions thrown in message handlers, routing, controller
selection, model binding, media-type formatters, or other filters.
`IExceptionLogger` sees all of them. "No per-controller code" is only true with
the logger.

The logger is **added**, not replaced — Web API 2 supports several, and if the
ERP already uses ELMAH or log4net, this does not switch it off. The *handler* is
replaced, because Web API permits exactly one.

### 4.3 .NET 8 modules

```csharp
builder.Services.AddErpErrorManagement(o => { o.ConnectionString = …; });
app.UseErpErrorManagement();   // first, so it wraps everything below
```

Same Core assembly, same envelope, same `erp_err` schema. A fault reported by a
new .NET 8 module lands on the **same fingerprint row** as the same fault
reported by the legacy API.

### 4.4 Forms, LOVs and submit actions — the one honest exception

These do not throw, so nothing can catch them. Capturing them requires one call
at the point of submit:

```csharp
if (this.form.invalid) {
  this.formErrors.reportInvalidForm(this.form, 'PurchaseOrderHeader');
  return;
}
```

If the ERP has a shared base component or a common `save()` helper — most
in-house ERPs do — that single line covers every form in the system. If it does
not, this is the one place where per-screen work is needed, and it is one line
per submit handler, not per field. **No field-by-field instrumentation is
required anywhere**, which is what the brief actually rules out.

Validation captures are severity `low` and never raise a dialog. They exist so
that "which field do our users fail most often, on which screen" becomes a
query. Interrupting a user over their own typo would be worse than not
capturing it.

**Values are never recorded.** Only the control path and the failing validator
key (`header.customerCode` / `required`), plus validator metadata like the
length limit. That is enough to diagnose and impossible to leak a national ID
with.

---

## 5. Database

### 5.1 Isolation

Everything lives in a dedicated `erp_err` schema. No existing table, view,
procedure, function, trigger, user or role is read, altered or dropped by any
script in `db/`. The application login needs one grant:

```sql
GRANT EXECUTE ON SCHEMA::erp_err TO [erp_app];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::erp_err TO [erp_app];
```

EXECUTE only. The application cannot read the error store directly, so a
SQL-injection hole anywhere in the ERP cannot read it either.

The connection string is configured separately from the ERP's own, even when it
points at the same database. That single indirection is what lets the error
store be moved to its own database — or its own server — later, without
touching a line of application code.

### 5.2 Code First vs Database First — and why neither, quite

The brief asks for a recommendation. Mine is: **ordered, idempotent SQL scripts
with a `SchemaVersion` ledger**, applied by DbUp or by hand, and **ADO.NET at
runtime** — not an ORM.

Three reasons, in order of weight:

1. **Two ORMs.** The framework must run inside a .NET Framework 4.7.2
   application (EF6) *and* a .NET 8 application (EF Core). Those are different
   ORMs with incompatible migration systems. One shared `netstandard2.0`
   assembly cannot depend on either.
2. **The capture path runs when the application is already in trouble.** A
   `DbContext` brings change tracking, model building, connection resiliency
   and a first-call warm-up. A `SqlCommand` brings none of it. When you are
   logging a deadlock, you do not want your logger to depend on the ORM that
   just produced it.
3. **A DBA has to be able to review it.** On a live ERP, "run this migration
   and trust the tool" is not an acceptable change request. `db/001…006.sql`
   can be read, reviewed, diffed and run by someone who will not run anything
   they cannot read. That review step is not optional on a production database.

A consuming application that wants a typed read model over the error data is
free to scaffold EF Core entities from the same schema — the tables are plain
and the procedures return flat result sets. That is a reporting concern, not a
capture concern.

### 5.3 How the database layer is captured without touching a single procedure

This is the part of the brief that sounds hardest and turns out to be nearly
free.

When a stored procedure raises an error, ADO.NET surfaces a `SqlException`
whose `Errors` collection **already carries** `Procedure`, `LineNumber`,
`Number`, `Class`, `State` and `Server`. So the entire database layer is
instrumented by reading an exception that was always there. No `TRY/CATCH`
added to any procedure, no trigger, no SQLCLR, no Extended Events session.

Two details that matter in practice:

* `Errors[0]`, not `SqlException.Number`, is read. When a procedure calls a
  procedure that raises, the outermost number is reported on the exception but
  `Errors[0]` holds the one that actually fired — with the procedure name and
  line a developer needs.
* Severity is derived from `Class`. A `RAISERROR`/`THROW` at class 11–16 inside
  a procedure is a **business rule the procedure is enforcing**, not a system
  failure; it is recorded at medium severity and returns 400. Class 17+ is a
  genuine server-side fault: critical, 500. Treating every procedure error as
  critical is how an error console becomes noise nobody reads.

**The limitation, stated plainly:** an error caught and swallowed *inside* a
procedure's own `TRY/CATCH` is invisible to everything outside that procedure —
no framework can see it without editing the procedure. If you need those too,
the option is a server-side Extended Events session on `error_reported` filtered
to severity ≥ 16, shipped into `erp_err` by a scheduled job. That is additive
and needs no procedure changes either, but it is not enabled by default because
it has a (small) standing cost on the instance and most shops will not want it.

### 5.4 The three-level data model

```
ErrorFingerprint   one row per DISTINCT PROBLEM      ~hundreds
   │  1:N
ErrorOccurrence    one row per ERROR EVENT           ~millions
   │  1:1
ErrorOccurrenceDetail   stack traces, payloads       the bulk of the storage
   │  N:M via TicketOccurrenceLink
Ticket             one row per ACTIONABLE INCIDENT   ~tens
   │  1:N
TicketStatusHistory     the audit trail
```

`ErrorOccurrence` deliberately contains **no `NVARCHAR(MAX)` columns**. It is
the table the console filters, counts and charts, and the one that grows
fastest. The heavy payload lives 1:1 in `ErrorOccurrenceDetail`, which lets
retention drop 40 KB stack traces at 30 days while keeping the trend data for
two years (§7).

### 5.5 Multiple schemas, multiple applications

The brief mentions modules that share a SQL Server instance but use different
schemas. Nothing in `erp_err` assumes a schema: `ApiApplication`,
`SqlSchemaName`, `SqlDatabaseName`, `TenantId` and `Environment` are columns on
the occurrence, and every search procedure filters on them. Three applications
across three schemas write to one `erp_err` and the console can show them
together or separately.

---

## 6. Deduplication — the fingerprint

The brief asks for "a suitable mechanism for identifying repeated or recurring
errors" and leaves the approach to me.

The mechanism is a **SHA-256 hash over a normalised signature**. Get it too
loose and two unrelated faults share a ticket; too tight and one broken LOV
opens 4,000 tickets because each message carries a different record id.

**Included** (stable): layer, category, exception type, the *shape* of the
message, the top 5 stack frames by function name, and the location appropriate
to the layer.

**Excluded** (volatile): record ids, GUIDs, SPIDs, dates, quoted literals,
numbers, file paths, line and column numbers, minified bundle hashes, user
names, timestamps.

```
Transaction (Process ID 71)  was deadlocked … in usp_PostJournal
Transaction (Process ID 143) was deadlocked … in usp_PostJournal
  → normalised: "Transaction (Process ID {n}) was deadlocked …"
  → same fingerprint, OccurrenceCount 2, one ticket
```

Which location fields count depends on the layer, and that is a judgement call
worth stating: a deadlock in `usp_PostJournal` is the *same* problem whichever
screen triggered it, but a template error in `InvoiceLineComponent` is *not* the
same problem as an identical one in `CustomerSearchComponent`. So the database
layer fingerprints on error number + object; the Angular layer fingerprints on
module + component.

**Stack frames drop file paths and line numbers on purpose.** Include them and
the same bug fingerprints differently after every release — the occurrence count
resets to 1 and the recurring-problem report, the one thing that makes a
permanent fix worth funding, never fires.

`SignatureText` — the exact string the hash was taken over — is stored next to
the hash. An administrator can always see *why* two errors were grouped. A hash
nobody can explain is a hash nobody will trust.

### 6.1 What deduplication actually does

* `ErrorFingerprint.OccurrenceCount` and `DistinctUserCount` are maintained
  incrementally, so "812 failures across 43 users" is a column read, not a
  `COUNT(DISTINCT)` over a 50-million-row table.
* While a fingerprint has an **open ticket**, new occurrences attach to it
  instead of creating another. The ticket's `LinkedOccurrenceCount` rises.
* When the ticket reaches a terminal status, `OpenTicketId` is cleared — so a
  recurrence *after* the fix opens a fresh ticket rather than reviving a closed
  one. That is how you find out the fix did not hold.
* Severity **escalates but never de-escalates**: if a problem was ever seen as
  critical, it stays critical.
* `usp_Error_RecurringProblems` is the report the brief asks for: problems
  ranked by occurrences in a window, with their distinct-user count.

### 6.2 Error vs ticket

Errors are **always** logged. Tickets are created only when:

1. the user presses **Report issue** in the dialog, or
2. an `AutoTicketRule` fires.

Rules are rows, not code: `MinSeverityId`, `CategoryId`, `LayerId`,
`ErpModuleMatch`, `EnvironmentMatch`, `MinOccurrences`, `WindowMinutes`. Shipped
conservative — a *critical* problem seen three times in an hour raises its own
ticket; everything else waits for a human.

Admins can also mute a fingerprint (`TriageState = 'muted'`, or
`MutedUntilUtc`). Occurrences are still counted; the dialog stops appearing and
auto-ticket rules stop firing. That is the pressure valve for a known,
already-being-fixed problem that is spamming users.

---

## 7. Retention and archiving

Two-stage, configuration-driven, batched:

```
hot table ──(ArchiveAfterDays)──► *_Archive ──(PurgeAfterDays)──► gone
```

Shipped defaults, all rows in `erp_err.RetentionPolicy`:

| Data set | Archive after | Purge after | Rationale |
|---|---|---|---|
| `occurrence_detail` | 30 days | never | The bulk of the storage. Nobody needs the stack trace of occurrence #3,412. |
| `occurrence` | 180 days | 730 days | Keeps a year+ of trend data queryable. |
| `ticket` | 365 days (after closure) | never | Tickets are the business record. |
| `audit` | 365 days | — | |

`usp_Retention_Apply` runs nightly from SQL Agent. Every move is in small
batches inside its own transaction, so the job never holds a long lock on a
table the ERP is writing to, and it is safe to kill at any point — the next run
resumes where it stopped. `@WhatIf = 1` reports what *would* move and changes
nothing; run that first on production.

Order matters and is enforced: detail rows leave before their occurrence (FK),
and an occurrence attached to a ticket is **evidence** — it ages out with its
ticket, never on its own.

On Enterprise/Developer edition, monthly partitioning of `ErrorOccurrence` on
`OccurredUtc` turns the archive step into a metadata-only `SWITCH`. Not assumed
here because it needs an edition guarantee I do not have; the script documents
the change if you want it.

---

## 8. Security and sensitive data

**The policy is an allow-list, not a deny-list.** This is the decision I would
most want reviewed, so here is the reasoning:

A deny-list ("redact anything called password, token, secret") is wrong the
moment someone adds a field it has never heard of — `iqamaNumber`, `bankIban`,
`otpCode`, `answerToSecurityQuestion`. It does not fail loudly; it quietly
writes the value into the error store, where it is read by every support user
and copied into every ticket export. You find out during an audit.

An allow-list fails the other way: an unclassified field shows up as `***` and
someone asks for it to be added. That is a support ticket, not a breach.

The allow-list lives in `erp_err.RedactionAllowList`, so extending it is a row,
not a front-end release.

Underneath the allow-list sits a **backstop sweep** over all free text —
messages, stack traces, SQL statements — for JWTs, `Bearer`/`Basic` headers,
connection-string passwords and Luhn-valid card numbers. This is the one place a
deny-list is right: not as the policy, but as a net under it.

Two details worth noting:

* Connection strings appear verbatim in the message of almost every
  connect-time `SqlException`. That is the single most common way a production
  password reaches a log file, and it is scrubbed specifically. The *server
  name* survives — it is diagnostic, not secret.
* Long digit runs are only masked if they **checksum as a card number**.
  Without that check, every GL account, document number and phone number in
  every message reads `***` and the store becomes useless for diagnosis.

The user-facing dialog contains **no technical information at all** — no stack
trace, no SQL text, no exception type, no server name. The only technical token
shown is the reference number, which is meaningless outside the error store and
is exactly what support needs the user to quote.

The end user's ticket view is filtered **at the database**
(`usp_Ticket_GetDetail @ForEndUser = 1`), not in the template. Filtering in the
UI would still have sent the data to the browser.

---

## 9. Deployment

1. **Database.** Run `db/001` … `db/006` in order against the ERP database.
   Idempotent — safe to re-run. `db/006` needs `@AppUser` edited first.
2. **Packages.** Publish the four packages to your internal feed.
3. **API.** Add the package reference and the three lines in `WebApiConfig`.
   Add the `ErpErrorStore` connection string.
4. **Front end.** Add the npm dependency and the two lines in `app.config.ts`.
   Add `erpErrorContext` to routes as you touch them — it degrades gracefully,
   errors from an unstamped route simply record no screen.
5. **SQL Agent.** Create the nightly retention job (script at the bottom of
   `db/005`).

**Rollout order matters.** Deploy the database and the API first, with the front
end unchanged. The API-side capture starts working immediately and you get a
week of real data — and a real answer to "how noisy is this?" — before any user
sees a dialog. Then deploy the front end with `notificationMode: 'silent'`, look
at what arrives, and only then turn the dialog on.

The master switch `capture.enabled` in `erp_err.Setting` turns the whole thing
off without a deployment, and takes effect within `config.cacheSeconds`.

---

## 10. Configuration

Everything the brief asked to be configurable is a row, not a constant:
severities, categories, layers, ticket statuses, **the allowed status
transitions**, queues, SLA targets, auto-ticket rules, redaction allow-list,
retention policies, and a general settings bag.

The ticket lifecycle in particular is data. Adding a status, or re-wiring
`New → Assigned → In Progress → Waiting → Resolved → Closed`, is an `INSERT`
into `TicketStatusTransition` — no redeploy of the API or the Angular app.
`usp_Ticket_ChangeStatus` refuses any transition not in that table, and honours
the `RequiresComment` / `RequiresAssignee` flags on each one.

---

## 11. What is verified, and how

`dotnet run --project dotnet/Erp.ErrorManagement.Tests` — 41 checks, all
passing:

* **All six T-SQL scripts parse** against the real SQL Server 2016 grammar,
  using Microsoft's own `ScriptDom` parser (the one SSMS and sqlpackage use).
  Parsed against the *oldest* supported version on purpose: a 2019-only
  construct would pass on a newer parser and fail on your server.
* **C# and TypeScript fingerprints agree**, hash for hash, on a shared corpus —
  including the exact signature layout.
* **SHA-256 matches `node:crypto`** for every input length 0–200 and 400 random
  Unicode strings (this found a real padding bug at lengths 55, 119, 183 …).
* **Redaction** keeps allow-listed fields, drops unknown PII fields, scrubs
  connection-string passwords while keeping the server name, and masks
  Luhn-valid card numbers but not document numbers.
* **Classification** maps deadlock → 503, optimistic concurrency → 409,
  `*BusinessException` → 400/low, and unwraps nested exception chains.

Every group includes a **positive control** — a check that deliberately expects
the negative result — so a suite that cannot fail cannot pass either.

The end-to-end flow is demonstrated in `demo/` and captured in
`docs/screenshots/`.

---

## 12. Limitations and open decisions

Stated plainly, because these are the things that matter at review time.

1. **The T-SQL has been parsed, not executed.** I have no SQL Server instance.
   Syntax is verified against the real grammar; semantics are not. Run
   `db/001…006` on a development database before production — I expect them to
   run clean, but "I expect" is not "I verified", and I would rather say so.
2. **The demo store is SQLite.** `demo/api` re-implements the procedure logic
   over SQLite so the framework can be seen working without a database server.
   It mirrors the T-SQL; it does not test it.
3. **Errors swallowed inside a procedure's own `TRY/CATCH`** are not visible to
   any external mechanism. §5.3 covers the Extended Events option.
4. **Form, LOV and submit-action capture needs one call per submit handler.**
   §4.4. Everything else is genuinely zero-touch.
5. **Component names after minification.** `ErpGlobalErrorHandler` infers the
   component from the top application stack frame. With `namedChunks` and source
   maps enabled this is the class name; without them it is a stable but opaque
   token. Route-level `screen` is unaffected and is usually the more useful
   field anyway.
6. **Three questions still open** (asked, not yet answered): how the Angular app
   identifies the user to the API; whether an existing helpdesk system is the
   system of record for tickets; and whether the front end uses standalone
   bootstrapping or `NgModule`. Sensible defaults are implemented for all
   three and are trivial to change.
