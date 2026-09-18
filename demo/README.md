# Run the demo

One command, one process, one URL. The only prerequisite is the **.NET 8 SDK** —
no Node, no npm install, no second terminal, no database server.

```bash
cd demo/api
dotnet run
```

Then open **http://localhost:5146** and load some sample history:

```bash
curl -X POST http://localhost:5146/api/error-management/demo/seed
```

(or just use the buttons — the demo works from empty, the seed only gives the
Support console some pre-existing history to look at.)

The pre-built Angular bundle is committed under `demo/api/wwwroot` and served by
the same process that hosts the API, which is why there is nothing to install.
That is demo plumbing only: in your ERP, IIS serves your Angular app exactly as
it does today and the framework adds nothing to that path.

---

## What to click, in order

**1. Purchase Order** — an ordinary ERP screen. Every button fails on purpose,
and none of the handlers behind them catch anything.

| Button | What it proves |
|---|---|
| Angular runtime | an uncaught `TypeError` in a component method |
| Unhandled promise | an async save nobody awaited — `window.onunhandledrejection` |
| Web API exception | HTTP 500 → a .NET `NullReferenceException` |
| **SQL Server deadlock** | **press it 3 times** — see below |
| Stored procedure error | `Invalid column name` in `usp_GetCostCentreLov` |
| Timeout | HTTP 504 |
| Connection failure | status 0, host unreachable |
| Save order (empty form) | form validation — a failure that never throws |
| Reload LOV | a lookup that fails |
| A call that works | proves the interceptor is passive |

Press **SQL Server deadlock three times**. The message carries a different
process ID every time, so three literally different strings arrive — and they
collapse to **one problem**. That is the deduplication doing the work that stops
one broken procedure opening 4,000 tickets.

**2. The dialog** — plain language, a reference number, and nothing technical:
no stack trace, no SQL text, no exception type, no server name. Type what you
were doing and press **Report issue** to get a ticket number immediately.

**3. Support console**

* *Recurring problems* — one row per distinct fault, with how many occurrences
  collapsed onto it and how many users hit it. This is the list that tells you
  what is worth fixing permanently.
* *Error history* — every occurrence, every layer. **Click any row** to jump to
  its correlation trail.
* *Ticket queue* — click a ticket for the full audit trail, time in each status,
  SLA flags, and every occurrence that deduplicated onto it. Use the **Move to**
  buttons to drive the lifecycle; the workflow is enforced, so an illegal
  transition is refused.
* *Correlation trail* — everything recorded under one correlation id, deepest
  layer first. This is how "the save button failed" becomes "deadlock 1205 in
  `usp_PostJournal` line 142".

**4. My issues** — the end user's own panel. Their tickets only, current status,
customer-visible history, the message thread and the resolution. If support has
moved a ticket to *Waiting for Information*, the user can **reply** — and the
ticket moves itself back to *In Progress* through the normal validated
transition.

To see that round trip: raise an issue, then in the Support console move it
Assigned → In Progress → Waiting for Information (with a question), then go to
My issues and answer it.

---

## A 65-second walkthrough

`docs/screenshots/` has the same flow as stills if you would rather not run it.

---

## What is real here, and what is not

**Real** — and shared with production, not re-implemented for the demo:

* the envelope contract, byte for byte;
* fingerprinting, redaction and classification (this project references the same
  `Erp.ErrorManagement.Core` assembly the production packages use);
* deduplication behaviour, the ticket lifecycle, transition validation, the
  audit trail, elapsed/active-processing metrics and SLA flags;
* ownership enforcement on the end-user panel.

**Not real** — the storage. Production persists through
`ERM.usp_Error_Capture` on SQL Server (`db/004_programmability.sql`). This
demo re-implements that logic over SQLite so it needs no database server. The
SQLite code is a **mirror** of the T-SQL, not a substitute for it: the T-SQL is
the deliverable, and it is verified separately by the ScriptDom parse in
`dotnet/Erp.ErrorManagement.Tests`.

Also not real: authentication. The demo stands in for your JWT with an
`X-Demo-User` header. Note that it still refuses to take a user id as a *query
parameter* — identity comes from the header the same way production takes it
from the validated token, never from something the caller can choose. Ownership
is genuinely enforced: ask for someone else's ticket and you get a 404.

---

## Reset

```bash
curl -X POST http://localhost:5146/api/error-management/demo/reset
curl -X POST http://localhost:5146/api/error-management/demo/seed
```

The SQLite file lives at `demo/api/bin/Debug/net8.0/demo-error-store.db`; delete
it for a completely clean start.

---

## Rebuilding the UI (only if you change the Angular code)

```bash
cd angular/erp-error-workspace
npm install
npx ng build erp-error-management     # the library first
npx ng build demo
cp -r dist/demo/browser/. ../../demo/api/wwwroot/
```

For live reload while developing, run `npx ng serve demo` on port 4200 with
`proxy.conf.json` pointing at 5146 — that is the two-terminal setup, and it is
only worth it if you are editing the front end.
