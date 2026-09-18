# ERP Error Management Framework — Technical Design

Version 2.0.0 · 18 September 2026

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

Answers to the clarification questions of 16 September are in §4.2a (NgModule),
§4.5 (JWT and public pages), §4.6 (EF6 EDMX / SP executor / EF Core),
§4.4 (non-throwing failures), §5.3 (swallowed SQL errors) and §13 (ticket
panels). Data loading and production performance are §14; support-console
access control, assignment and manually raised tickets are §15.
Compliance with the LinkedScam ERP database standards is §16.

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

#### Failures that return a value instead of throwing

The harder half of the same question: code that catches internally and returns
a failure result.

```ts
try { … } catch (e) { this.toast('Could not save'); return null; }
const r = await this.api.post(…);  if (!r.success) { return; }
if (!rows.length) { this.message = 'No cost centres found'; return; }
```

No global handler can see any of these - nothing propagates. And an HTTP
interceptor cannot see the middle one either: the transport returned 200, only
the *operation* failed. There is no way to capture a value-returning failure
without some signal at the point that decides it is a failure, because that
decision exists only in the calling code.

What the framework does is make that signal as close to free as possible. Three
forms, all funnelling into the same reporter as the automatic paths:

| Shape in your code | What you add |
|---|---|
| `{ success: false, errorCode: … }` from an HTTP call | `.pipe(erpReportFailedResult({ actionName: 'savePO' }))` |
| Any stream whose value means failure | `.pipe(erpReportIf(r => !r.ok, r => \`refused: \${r.code}\`))` |
| A lookup that came back empty | `.pipe(erpReportIfEmpty('COST_CENTRE'))` |
| An existing `catch` block | `this.erpErrors.reportHandled(e, { actionName: 'recalc' })` |
| A business rule your code refused | `this.erpErrors.reportBusinessRule('CREDIT_LIMIT', { code })` |
| An `async` method whose caller handles rejection | `erpObserveAsync(() => this.api.post(…), reporter)` |

None of them alter control flow. The operators are `tap`-based: the value passes
through untouched and the subscriber behaves exactly as before.
`reportHandled` does not rethrow. `erpObserveAsync` reports and then rethrows
the original, unchanged.

**The highest-leverage line available:** if the ERP has a shared API wrapper -
most in-house codebases do - putting `erpReportFailedResult()` in that one
wrapper covers every call in the system at once, with no per-screen work at all.

Handled failures default to **silent**. The calling code has already told the
user something; a framework dialog on top of its own toast would make the
experience worse, not better.

### 4.5 JWT, and pages that are public

Two requirements that pull in opposite directions: identify logged-in users from
the JWT, and still capture errors from unauthenticated users.

**Identity.** Read from the principal the ERP's own JWT middleware already
established. The framework never validates a token itself - a second validator
would be a second place to get signing keys, clock skew and issuer checks
wrong, and it could *disagree* with the ERP's, which is worse than not checking.
`ErrorCaptureOptions.UserProvider` is the authoritative hook; failing that, the
correlation handler reads the standard claims (`sub`, `NameIdentifier`, `name`,
`tid`) so the framework is useful with no wiring on day one.

**Public pages.** `POST errors` and `POST errors/beacon` are
`[AllowAnonymous]`. Identity is attached when a token is present and left empty
otherwise - an anonymous occurrence is a complete, useful record, just without a
user. The endpoint table:

| Endpoint | Auth | Why |
|---|---|---|
| `POST errors` | anonymous allowed | a public page has no token, and those errors matter |
| `POST errors/beacon` | anonymous allowed | fires during unload; no chance to negotiate auth |
| `POST tickets` | authenticated *by default* | a ticket has an owner and notifies people |
| `GET tickets/mine` | authenticated | scoped to the caller in SQL |
| `GET tickets/{n}` | authenticated + **ownership** | see §13 |

**The consequence nobody asks about until later:** an anonymous capture endpoint
means anyone who can reach the ERP can write rows into the error store, at any
rate. Left open that fills the store with junk, grows `erp_err` until it affects
the ERP database it shares a disk with, and stays unnoticed for weeks because
capture failures are deliberately quiet. So anonymous capture is **rate-limited
per client IP** (token bucket, 60/min burst 20 by default). Authenticated
capture is deliberately *not* limited: a signed-in user triggering 500 errors is
a real incident, and throttling it would discard the evidence of the worst thing
happening that day.

A batch over the limit is **partially** accepted rather than rejected - dropping
ten envelopes because five tokens remain throws away evidence already received.

Anonymous **ticket** creation is off by default. A ticket carries free text,
lands in a support queue and notifies people; an open endpoint for that is a
spam channel aimed at your support team. With it off, an anonymous user still
sees the dialog and the error reference, which is what they need in order to
quote it - and the dialog hides its "Report issue" button rather than offering
one that will be refused (`canCreateTicket` on the capture result).

**One thing I cannot do from inside the package:** `[AllowAnonymous]` only has
an effect where a global authorize filter is in place. If the ERP protects routes
some other way - a custom HTTP module, IIS-level rules, an OWIN stage - that
mechanism must also exempt the two capture routes. It is a one-line allow entry,
but it does have to be done.

### 4.6 Three different execution paths to the database

The ERP reaches SQL Server three ways, and each wraps a `SqlException`
differently:

| Path | Wrapper types seen |
|---|---|
| EF6 EDMX / `ObjectContext` | `UpdateException`, `EntityException`, `EntityCommandExecutionException`, `EntitySqlException`, `OptimisticConcurrencyException` |
| Custom ADO.NET SP executor | none - `SqlException` propagates directly |
| EF Core (Code First) | `DbUpdateException`, `DbUpdateConcurrencyException` |

All are unwrapped, recursively and by **type name** rather than by type. Core is
`netstandard2.0` and must load inside both a .NET Framework 4.7.2 app using EF6
and a .NET 8 app using EF Core - referencing either ORM would break the other.
Matching on the name keeps it decoupled and costs nothing: these names have been
stable across every EF version that exists.

This matters more than it looks. Without unwrapping, the captured exception type
is `DbUpdateException` for *every* database fault in the system, they all
fingerprint together, and the database layer of the error store becomes one
enormous useless bucket.

`DbUpdateConcurrencyException` and `OptimisticConcurrencyException` classify as
concurrency → 409, and `DbEntityValidationException` as a business rule → 400,
rather than falling through to "unhandled exception / critical". Note that EF6's
validation exception has a famously useless message ("Validation failed for one
or more entities") - the detail lives in `EntityValidationErrors`, which Core
cannot read without referencing EF. Surface it through `BeforeSend` if you want
it.

The **frozen EDMX is not a problem** for this framework: nothing here reads or
extends your model. The EDMX is a consumer of `SqlConnection`, and the framework
observes the exception that comes back out.

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

`dotnet run --project dotnet/Erp.ErrorManagement.Tests` — 143 checks, all
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
* **ORM unwrapping** for every EF6/EDMX and EF Core wrapper, including nested
  ones — with a positive control proving a *non*-wrapper is left alone.
* **The anonymous throttle** grants within burst, refuses beyond it, keeps a
  separate bucket per client, and partially grants an oversized batch.
* **End-user ticket access**: structural assertions that both end-user read
  paths are gated by the ownership function, that an anonymous caller owns
  nothing, and that eight named internal fields are absent from the end-user
  view. Asserted against comment-stripped SQL — the first version of this check
  matched raw text and fired on a comment listing the fields it deliberately
  does *not* select, which is a check worth nothing.
* **NgModule support** is verified by build, not by assertion:
  `projects/legacy-ngmodule-check` is a real NgModule app that AOT-compiles
  against the built library.
* **The SQL that the dynamic procedures actually BUILD** is parsed, not just
  the script that builds it. Every branch combination is expanded and parsed
  (12 variants across three procedures). Parsing only the outer script would
  leave a syntax error inside a string literal to be discovered in production.
  Plus structural assertions that `@SortBy` is never concatenated, that the
  per-row correlated count is gone, that the correlation trail is bounded, and
  that every whitelisted sort ends in a unique tiebreaker.

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
6. **Answered as of 16 September.** JWT with public pages → §4.5. Mixed
   NgModule + standalone → §4.2a. No external helpdesk, so this framework is
   the system of record → §13.

7. **Route protection outside Web API's filter pipeline.** If the ERP guards
   routes with a custom HTTP module or IIS rules rather than a global authorize
   filter, `[AllowAnonymous]` on the two capture endpoints has no effect and
   that mechanism must exempt them explicitly. One line, but not something the
   package can do for you.

8. **The anonymous throttle is per-process and in-memory.** Behind a load
   balancer the effective limit is per-node × node count. That is the right
   trade for a guard rail — it must not add a Redis round trip to the path
   taken when the application is already failing — but it is not a precise
   meter, and it is not an access control.

9. **`db/008` (Extended Events) is written but I would not install it yet.**
   §5.3 sets out why, and `db/009` is the cheaper answer to the same problem.


---

## 13. Ticket panels

No external helpdesk exists, so this framework is the system of record. Both
panels are implemented.

### 13.1 Support / admin console

Recurring problems (ranked by occurrences with distinct-user counts), full error
history across every layer, the ticket queue, the cross-layer correlation trail,
and per-ticket: the complete audit trail, time in each status, SLA breach flags,
and every occurrence that deduplicated onto the ticket.

Status changes go through `usp_Ticket_ChangeStatus`, which refuses any
transition not present in `TicketStatusTransition` and honours its
`RequiresComment` / `RequiresAssignee` flags. The workflow is data: adding a
status or rewiring the path is an `INSERT`, not a redeploy.

### 13.2 End-user "My Tickets"

`db/007` plus `GET tickets/mine`, `GET tickets/{n}`, `POST tickets/{n}/comments`.

The user sees their own tickets, current status, the customer-visible history,
the message thread, and the resolution once there is one. They can **reply**,
which is what makes `Waiting for Information` a conversation rather than a dead
end - and a reply automatically moves the ticket back to `In Progress` through
the normal status-change path, so the audit row and the paused-minutes
accounting are written exactly as they are for a support-driven change. If the
configured workflow forbids that transition, the comment still stands and the
move is skipped: the workflow is the authority, not the convenience.

Three properties worth stating because they are easy to get wrong:

**Ownership is enforced in SQL**, in `usp_Ticket_GetForUser` and
`usp_Ticket_AddUserComment`, via `fn_UserOwnsTicket`. Not in the API route and
not in the component - so no future caller can forget it. Verified in the demo:
the owner gets 200 on their ticket, a different user gets 404 on the same
number.

**"Not yours" and "does not exist" are indistinguishable.** Returning 403 for
one and 404 for the other confirms which numbers are real, and ticket numbers
are sequential. Both return nothing.

**Redaction happens in the procedure, not the template.** The end-user view
never selects `AssignedToUserName`, `FingerprintId`, the SLA breach flags, the
elapsed metrics, `ReopenCount` or `ChangedByUserName`. Filtering those in the UI
would still have sent them to the browser, where anyone can read them in the
network tab. The test suite asserts their absence from the SQL.

The resolution note is withheld until the ticket is actually resolved - a
half-written note read as a promise is worse than no note - and a closed ticket
is read-only, because a conversation nobody is watching is worse than a closed
door.


---

## 14. Data loading and production performance

Short answer: **server-side, always.** Filtering, sorting and paging are all
done in SQL, and the browser never receives more than one page. No list
endpoint in the framework can return an unbounded result set.

### 14.1 What each read does

| Procedure | Paging | Filtering | Sorting | Bound |
|---|---|---|---|---|
| `usp_Error_Search` | OFFSET/FETCH **or keyset** | 20 predicates, all in SQL | 8 whitelisted keys | `@PageSize` ≤ 500 |
| `usp_Ticket_Search` | OFFSET/FETCH | 15 predicates | 8 whitelisted keys | `@PageSize` ≤ 500 |
| `usp_Error_RecurringProblems` | OFFSET/FETCH | 5 predicates | 7 whitelisted keys | `@PageSize` ≤ 500 |
| `usp_Ticket_ListForUser` | OFFSET/FETCH | scoped to the caller | waiting-first, then date | `@PageSize` ≤ 200 |
| `usp_Ticket_GetDetail` | n/a — one ticket | n/a | n/a | linked occurrences `TOP 200` |
| `usp_Error_GetCorrelationTrail` | n/a | one correlation id | layer, then time | `TOP (@MaxRows)`, ≤ 1000 |
| `usp_Dashboard_Summary` | n/a — aggregates | date window | n/a | `TOP 10` per breakdown |

`usp_Error_Search` also defaults to **the last 30 days** when no date filter and
no specific identifier is supplied. An unbounded default is how a support
console takes the ERP's SQL Server down on its first day.

### 14.2 Sorting without a SQL-injection hole

Parameterised sorting has two obvious implementations and both are wrong:

* `ORDER BY CASE @SortBy WHEN 'severity' THEN … END` is safe but not sargable,
  so SQL Server sorts the entire filtered set on every request — discarding the
  very index that makes the default view fast.
* Concatenating `@SortBy` into dynamic SQL is fast and is an injection hole, in
  the one schema that holds every error message in the system.

So the caller's value is used **only as a lookup key** into
`erp_err.SortWhitelist`. What reaches the `ORDER BY` clause is text I wrote.
An unrecognised key silently falls back to the default rather than erroring,
because a stale bookmark should not break the console — and the response
reports the sort that was **actually applied**, not the one that was asked for.

Every whitelisted clause ends with a unique tiebreaker (`OccurrenceId`,
`TicketId` or `FingerprintId`). Without one, two rows with equal sort values can
swap places between page 1 and page 2 — so one row appears twice and another is
never shown. That is the classic "pagination loses records" bug, and it reads to
whoever reports it as data loss.

### 14.3 The scale ceiling nobody mentions: OFFSET

`OFFSET 500000 ROWS FETCH NEXT 50` has to walk and discard half a million rows
before returning anything. Page 3 is instant; page 10,000 of a 40-million-row
table is a scan.

So `usp_Error_Search` also accepts a **keyset cursor**
(`@AfterOccurredUtc` + `@AfterOccurrenceId`). The cost of a keyset seek does not
grow with depth. The trade is that it is next/previous only — you cannot jump to
page 47 — so both modes exist:

* **OFFSET** for the console, where people filter down and look at the first few
  pages and want "1–50 of 1,284";
* **keyset** for infinite scroll and for any programmatic sweep over a large
  range, where depth is unbounded.

Keyset is only coherent for the default chronological order, because the cursor
*is* `(OccurredUtc, OccurrenceId)`. Ask for both a cursor and a different sort
and the sort wins — silently reordering someone's results is worse than
ignoring a cursor they can re-request.

`@IncludeTotalCount` exists for the same reason. `COUNT(*) OVER ()` is often the
expensive half of the query on a large filtered set; a console needs the total,
an infinite-scroll view does not.

### 14.4 The defect this section found

`usp_Error_RecurringProblems` as written in v1.1 was:

```sql
FROM erp_err.ErrorFingerprint f
CROSS APPLY (SELECT COUNT_BIG(*), COUNT(DISTINCT o.UserName)
             FROM erp_err.ErrorOccurrence o
             WHERE o.FingerprintId = f.FingerprintId
               AND o.OccurredUtc >= @FromUtc) w
WHERE w.WindowOccurrences >= @MinOccurrences
```

That `CROSS APPLY` runs **once per fingerprint** — including for every
fingerprint with no occurrence in the window at all — and the filter that would
have eliminated most of them is applied *after* the count. With 4,000
fingerprints over 40 million occurrences that is 4,000 index seeks, each with
its own distinct-count sort.

It was fine on demo data and would have fallen over on real data, which is the
worst kind of defect: nothing reveals it until the table is big and somebody is
already relying on the screen.

Rewritten to aggregate the window **once**, with the threshold applied during
aggregation via `HAVING`, then join the result. The cost now tracks the size of
the *window* rather than the size of the *table*. `db/010`.

Two smaller ones fixed at the same time: `usp_Error_GetCorrelationTrail` had no
limit at all (a cascading failure can put thousands of rows under one
correlation id), and it now returns the true total alongside the capped rows so
a truncated trail is visibly truncated rather than looking complete.

### 14.5 Indexes

`db/010` adds the indexes the new sorts need, because offering a sort with no
supporting index is how you ship the "fast in the demo, crawls in production"
failure this section exists to avoid:

| Index | Serves |
|---|---|
| `IX_Occurrence_Module_Occurred` | the most common shape: recent errors for one module |
| `IX_Occurrence_Severity_Occurred` | sort/filter by severity within a window |
| `IX_Occurrence_Window_Aggregate` | the recurring-problems `GROUP BY` — covering, so no base-table lookup |
| `IX_Occurrence_Unticketed` (filtered) | the triage inbox; stays small |
| `IX_Ticket_Open_Created` | oldest-open-first and SLA-breach-first queues |
| `IX_Ticket_Unassigned` (filtered) | unassigned queue |
| `IX_Ticket_Reporter_Created` / `…ReporterId…` | "My Tickets" — the only one an ordinary user can trigger, so the one that must never be slow |

All created with existence checks, so `db/010` is safe to re-run on a live
database. A **columnstore** index on `ErrorOccurrence` would make the dashboard
aggregates substantially faster and is written out in a comment — not created,
because it changes the plan for every query in the script and wants testing on
your data in a maintenance window.

### 14.6 The console UI

The Angular admin console requests one page at a time, with the filters, sort
key and page number as query parameters, and re-requests on every change. There
is no client-side filtering or sorting anywhere — which also means there is no
virtual scrolling to configure, because there is never a large array in the
browser to virtualise.

Changing the sort returns to page 1. Staying on page 9 of a re-sorted list shows
an arbitrary slice of a different ordering, which again reads as data loss.

The demo previously took the newest 300 rows and filtered them **in memory**.
That is worth naming because it is subtly wrong rather than merely slow:
filtering by severity *after* capping means "show me critical errors" searched
only the most recent 300 rows, so a critical error from an hour earlier simply
was not there. Fixed in the demo too — a reference implementation that
demonstrates the wrong pattern is worse than no reference implementation.


---

## 15. Support-console access, assignment, and manual tickets

### 15.1 How the console is restricted

Two layers, and it matters which one is which.

**Authentication** is the ERP's own JWT middleware. The framework never
validates a token itself — a second validator is a second place to get signing
keys, clock skew and issuer checks wrong, and it could disagree with yours.

**Authorisation** is `ErpAdminAuthorizationFilter` plus the `erp_err` support
roster. Every action on `AdminController` carries a
`[RequiresSupport(capability)]` attribute, and the filter resolves the caller
and checks that specific capability.

An Angular route guard is **not** the boundary. A guard hides a menu item;
anyone who can open a browser console can call
`/api/error-management/admin/errors` directly, and the error store holds every
stack trace, SQL object name and user name in the system — it is the single most
useful thing in the ERP for someone probing it. The guard exists only so people
who cannot use the console are not shown a menu item they cannot click.

**The filter fails closed.** If the roster cannot be read, the answer is no.
That is the opposite of every other failure path here — everywhere else, losing
an error record beats breaking the ERP — and the asymmetry is deliberate: an
authorisation check that fails open during a database blip is not a check.

### 15.2 Capabilities, not a hierarchy

| Role | view list | diagnostics | manage tickets | assignable | triage | configure |
|---|---|---|---|---|---|---|
| `support_agent` | ✓ | ✓ | ✓ | ✓ | | |
| `support_lead` | ✓ | ✓ | ✓ | ✓ | ✓ | |
| `developer` | ✓ | ✓ | ✓ | ✓ | ✓ | |
| `support_viewer` | ✓ | | | | | |
| `administrator` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

Flags rather than levels, because a hierarchy forces you to decide whether "can
triage" outranks "can configure" and that question has no correct answer — real
teams have people who do one and not the other.

Note that **diagnostics is separate from view**. Seeing that an error happened
on a screen is one permission; seeing its stack trace, SQL object and request
payload is another, because that is where the sensitive detail lives. A manager
who needs the dashboard and the recurring-problem report gets `support_viewer`
and cannot open a stack trace.

Verified end to end in the demo:

| Endpoint | normal user | support lead | read-only viewer |
|---|---|---|---|
| `admin/dashboard` | 403 | 200 | 200 |
| `admin/errors` | 403 | 200 | 200 |
| `admin/problems` | 403 | 200 | 200 |
| `tickets` (queue) | 403 | 200 | 200 |
| `admin/assignable-users` | 403 | 200 | **403** |
| `admin/error/{ref}` (stack trace) | 403 | 200 | **403** |
| `tickets/mine` (own tickets) | **200** | 200 | 200 |

### 15.3 Why the roster and not just a role claim

Reading a role straight off the JWT is what most integrations do, and
`SupportRoleClaims` supports it. The default is the roster because of two
things:

1. **Token lifetime.** Revoking support access has to take effect now, not when
   someone's token happens to expire.
2. **Who owns the list.** Support membership is operational data a support lead
   should be able to change. In the identity provider, every change becomes a
   request to whoever administers auth.

If you set `SupportRoleClaims`, the two are OR'd — so adding a claim **grants**
access and removing someone from the roster does **not** revoke it while they
still hold the claim. Leave it empty if you want the roster to be
authoritative.

### 15.4 Assignment

The assignee is picked from `usp_SupportUser_ListAssignable`, which returns only
active, available people whose role has `CanBeAssigned`, **ordered by current
open workload** so a lead can see who is already buried rather than assigning
alphabetically. A free-text assignee field looks harmless right up to the first
typo, after which the ticket belongs to nobody and appears in no queue — so the
target is validated in SQL and a bad one is rejected.

**Assignment is now audited properly, and previously was not.**
`usp_Ticket_ChangeStatus` wrote the assignee to the ticket row and the
transition into `Assigned` appeared in the history with who made the change —
but the history never recorded **who the ticket was assigned to**. And
reassignment between two support users is not a status change, so it left no
trace at all. You could see the current assignee and nothing about how it got
there.

`usp_Ticket_Assign` fixes both. It writes a history row every time, carrying
`AssignedToUserName`, `PreviousAssignedToUserName` and
`ChangeKind = 'assignment'`. The row deliberately keeps the same status on both
sides, because it is an assignment and not a transition — recording it as a
transition would corrupt the minutes-in-status accounting.

Who *performed* it always comes from the token, never from the request body.
Accepting that from the caller would make the audit trail worth nothing.

Assignment rows are `IsCustomerVisible = 0`: which engineer holds a ticket is
internal, and showing the user invites them to chase that person directly.

### 15.5 Manually raised tickets

`Ticket.FingerprintId` used to be `NOT NULL`, so every ticket had to hang off a
captured occurrence. A user who wants to report "the totals on this report look
wrong" has no error to attach — nothing threw. That is an ordinary support
request and the schema could not represent it.

`db/011` relaxes the column, adds `TicketSource` (`error` | `manual`), and adds
a `CHECK` constraint so a ticket is one or the other and never neither.

The end user gets **+ New issue** on My Tickets, with a category list that is
rows in `erp_err.RequestCategory` rather than a hard-coded enum. Support can
raise one on a user's behalf — a phone call — via
`POST admin/tickets/on-behalf`, and the ticket is owned by **the user**, so it
appears in their My Tickets rather than the agent's.

Three decisions worth flagging:

**Severity comes from the category, not from the user.** Otherwise everyone
marks their request critical and the SLA queue stops meaning anything.

**Manual tickets are not deduplicated.** Fingerprint deduplication answers "is
this the same fault?" and there is no fault here. Two people describing the same
annoyance in their own words are two requests, and merging them would discard
one person's description. Recurring-problem analysis therefore ignores manual
tickets, which is correct — they are not errors.

**Ownership comes from the token.** The owner fields are `[JsonIgnore]`, so a
client cannot set them even by sending them, and nobody can raise a ticket in
someone else's name.


---

## 16. LinkedScam ERP database standards

Version 2.0.0 applies the three standards documents. This is a breaking schema
change, which is why it is a major version: **nothing is migrated in place, and
the framework has no production data yet, so the scripts create the new shape
directly.** If you had already deployed 1.x anywhere, drop the `erp_err` schema
and run the new scripts.

### 16.1 Naming

`erp_err` is gone. Every object is `ERM.ERM_TableName`, and every primary key is
named after its table:

| Was | Is |
|---|---|
| `erp_err.ErrorOccurrence` | `ERM.ERM_ErrorOccurrence` |
| `ErrorOccurrence.OccurrenceId` | `ERM_ErrorOccurrence.ERM_ErrorOccurrenceID` |
| `erp_err.Ticket` | `ERM.ERM_Ticket` |
| `Ticket.TicketId` | `ERM_Ticket.ERM_TicketID` |

Foreign-key and other id columns take your casing (`TicketStatusID`,
`SeverityID`), matching the `TicketStatusID` example in the structure document.

**What deliberately did NOT change: the procedure result columns.** The
procedures are the API — the C#, and through it the browser, consume their
output. Renaming `OccurrenceId` to `ERM_ErrorOccurrenceID` in a *result set*
would churn the application contract for a storage decision, so the procedures
alias back to the stable names. Your standards govern tables; a result-set alias
is not a table.

### 16.2 Table structure

All 28 tables now carry the standard columns in the prescribed order: `ROWID`,
`DBNo`, `AppNo`, then the business columns, then `IsActive`, `IsDeleted`,
`CreatedBy`, `CreatedDate`, `UpdatedBy`, `UpdatedDate`. Enforced by a test that
walks every `CREATE TABLE` and checks both presence and order, so a table added
later cannot quietly skip it.

**`CreatedBy INT NOT NULL` needed a decision.** The framework writes rows with no
ERP user behind them: an error from a public page, an occurrence written by the
capture pipeline, reference data seeded by the deployment scripts, a ticket
raised by an automatic rule. There is no user id to put in the column.

So there is a reserved system user id, supplied by `ERM.fn_SystemUserID()`, and
every table defaults `CreatedBy` to it. That satisfies the standard without
threading a user id through code paths that genuinely do not have one. **Set it
before go-live:**

```sql
ALTER FUNCTION ERM.fn_SystemUserID() RETURNS INT AS BEGIN RETURN <your id> END;
```

It returns a **constant**, deliberately. A version that reads the value from a
settings table would be a scalar UDF doing a table read, used as a column
default on `ERM_ErrorOccurrence` — the highest-volume table in the framework —
so it would execute once per row inserted. That is a well-known way to turn a
fast insert into a slow one.

**Identity note.** Your `CreatedBy` is an int ERP user id; the framework also
records the user from the JWT as a string (login name and claim id), because
that is what the token actually carries. Both are kept: the int for your
standard, the string for display and for matching tickets to their owner. If
your token carries the int user id in a claim, point `UserProvider` at it and
`CreatedBy` will be populated from the real user instead of the system id.

### 16.3 Reference codes

`LS-ERM-TKT-YYMMDD-X` and `LS-ERM-ERR-YYMMDD-X`, counters independent and
restarting each UTC day.

The previous implementation used a SQL `SEQUENCE`, which is ideal for a
monotonic number and **cannot reset daily at all** — so this is a different
mechanism, not a reformat.

Point 7 of the standard is the hard part, and it rules out the obvious
implementation. `SELECT MAX(counter) + 1` is a read followed by a write; two
sessions read the same value and write the same reference. That is not a rare
race for this framework specifically — error capture is *bursty by nature*, and
one bad deployment produces hundreds of errors in the same second from different
users across several application instances.

So the increment and the read are a **single statement**:

```sql
UPDATE ERM.ERM_ReferenceCounter
   SET LastValue = LastValue + 1
OUTPUT inserted.LastValue INTO @Claimed
 WHERE RefType = @RefType AND RefDate = @Today;
```

There is no window between reading and writing because there is no read. The
one remaining race — two sessions creating the first row of a new day — is
settled by the primary key: one INSERT wins, the loser catches the duplicate-key
error and re-runs the UPDATE. A retry loop rather than `MERGE` under
`SERIALIZABLE`, because MERGE has its own documented deadlock behaviour and this
path runs at most once per type per day.

The date comes from `GETUTCDATE()` to match every other timestamp in the schema.
Using local time would reset the counter at a different moment than the data is
stamped, producing two references numbered `-1` on the same calendar day at the
boundary.

**Proven, not asserted.** `tools/verify-reference-concurrency.mjs` fires 120
simultaneous ticket creations at the running demo:

```
PASS  every request produced a reference (120)
PASS  all references match LS-ERM-TKT-260918-N
PASS  no duplicates across 120 concurrent requests
PASS  counter is a contiguous 1..120, no gaps and no repeats
```

Contiguity matters as much as uniqueness: no gaps means nothing was skipped, no
repeats means nothing was handed out twice. The check includes a positive
control that feeds it a deliberately duplicated list, because "no duplicates
found" proves nothing unless the checker can find one.

The demo is SQLite and production is SQL Server, so this exercises the *shape*
of the algorithm — atomic increment-and-return, no read-then-write window —
rather than SQL Server's locking. Both sides use the same shape for the same
reason.

### 16.4 What is enforced automatically

Twenty checks in the suite, so the standards stay applied rather than being a
one-off tidy-up: no `erp_err` anywhere, every table `ERM.ERM_*`, all nine
standard columns present and correctly ordered on every declared table, the
system-user default present and constant, UTC timestamps, the reference format,
separate per-type counters, the atomic increment, the absence of `SELECT MAX`,
and the absence of the old sequence.
