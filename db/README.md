# Deployment runbook

**Test first. EBS-PROD only once the framework is mature.** That is the agreed
sequence and this runbook is written around it — the promotion checklist in §5
exists so that moving to EBS-PROD is a decision with evidence behind it rather
than a date.

Everything the framework creates lives in the **`ERM`** schema. No existing ERP
table, view, procedure, function, trigger, user or role is read, altered or
dropped by any script here. That is what makes the Test deployment low-risk:
the worst case is an unused schema.

---

## 1. Script order

Run in numeric order, in one database, as a login that can create objects in a
new schema.

| Script | What it creates | Required? |
|---|---|---|
| `001_schema_and_config.sql` | `ERM` schema, `fn_SystemUserID`, version ledger, all configuration tables | yes |
| `002_core_tables.sql` | reference counter + generator, fingerprints, occurrences, tickets, audit trail | yes |
| `003_seed_reference_data.sql` | severities, categories, layers, statuses, workflow, SLAs, redaction allow-list | yes |
| `004_programmability.sql` | `usp_Error_Capture` and the rest of the procedures | yes |
| `005_retention_and_archive.sql` | archive tables + the nightly batched retention job | yes |
| `006_security.sql` | least-privilege grants — **edit `@AppUser` first** | yes |
| `007_end_user_ticket_access.sql` | "My Tickets", with ownership enforced in SQL | yes |
| `010_search_performance.sql` | server-side sorting, keyset paging, supporting indexes | yes |
| `011_support_access_and_manual_tickets.sql` | support roster/roles, audited assignment, manual tickets | yes |
| `008_optional_swallowed_sql_errors.sql` | Extended Events capture of errors swallowed inside procedures | **no** |
| `009_optional_catch_block_helper.sql` | one-line capture from an existing `CATCH` block | **no** |

`008` and `009` are optional and **should not** go into Test on day one. See
`docs/ARCHITECTURE.md` §5.3 — `008` needs a server-level permission and is
noisy; `009` is the one I would recommend, and only once you know you have a
blind spot worth paying for.

All scripts are idempotent. Re-running them is safe and is how you apply an
update.

---

## 2. Two things to set before anything runs

**The system user id.** Every table has `CreatedBy INT NOT NULL`, per the
LinkedScam standard, but the framework writes rows with no ERP user behind them
— errors from public pages, occurrences written by the capture pipeline, seed
data, tickets raised by an automatic rule. A reserved id covers those:

```sql
ALTER FUNCTION ERM.fn_SystemUserID() RETURNS INT AS BEGIN RETURN <your id> END;
```

Ships as `0`. Set it to whatever your reserved system/service user is.

**The application login.** Edit `@AppUser` at the top of `006_security.sql`
before running it. The application needs `EXECUTE` on `ERM` and nothing else —
no `SELECT`, no table rights. A SQL-injection hole anywhere in the ERP then
cannot read the error store, which is worth having because that store holds
every stack trace and SQL object name in the system.

---

## 3. Test deployment

1. Run `001` … `007`, then `010`, `011`.
2. Confirm the ledger: `SELECT * FROM ERM.ERM_SchemaVersion ORDER BY ScriptName;`
   — nine rows.
3. Set `fn_SystemUserID` and run `006` with your real `@AppUser`.
4. Add your support staff so the console is reachable:

```sql
INSERT ERM.ERM_SupportUser (UserName, DisplayName, RoleID)
VALUES (N'<login>', N'<name>', 2);   -- 2 = support_lead
```

   Nobody can open the support console until there is a roster row — the
   authorisation check fails closed, deliberately.
5. Create the nightly retention job (script at the bottom of `005`). Run
   `EXEC ERM.usp_Retention_Apply @WhatIf = 1;` first: it reports what *would*
   move and changes nothing.
6. Point the API at the database (`ErpErrorStore` connection string) and add the
   three lines to `WebApiConfig.Register`.
7. Deploy the front end **with `notificationMode: 'silent'`** at first — see §4.

### Rollout order within Test

Deploy the database and the API first, with the front end unchanged. API-side
capture starts working immediately and you get real data — and a real answer to
"how noisy is this?" — before any user sees a dialog. Then add the front end
silently, look at what arrives, and only then turn the dialog on.

`ERM.ERM_Setting` has a master switch, `capture.enabled`, which turns the whole
thing off without a deployment and takes effect within `config.cacheSeconds`.

---

## 4. What to watch during Test

| Check | Query |
|---|---|
| Is anything arriving? | `SELECT COUNT(*) FROM ERM.ERM_ErrorOccurrence;` |
| Did capture itself fail? | `SELECT * FROM ERM.ERM_DeadLetter ORDER BY ReceivedUtc DESC;` |
| How noisy is it really? | `EXEC ERM.usp_Error_RecurringProblems;` |
| Are references well-formed and unique? | see below |
| Is the dedup ratio sensible? | `EXEC ERM.usp_Dashboard_Summary;` |

`ERM_DeadLetter` is the one to watch and the easiest to forget. The framework is
built to fail quietly rather than break the ERP, so a capture problem will *not*
announce itself — it lands there instead. An empty dead-letter table after a
week of Test is the single best signal that the integration is sound.

Reference codes, which is the thing most worth confirming on real hardware:

```sql
-- every code well-formed?
SELECT COUNT(*) AS Malformed
FROM   ERM.ERM_ErrorOccurrence
WHERE  ErrorReference NOT LIKE 'LS-ERM-ERR-[0-9][0-9][0-9][0-9][0-9][0-9]-%';

-- any duplicates? must be 0
SELECT ErrorReference, COUNT(*) FROM ERM.ERM_ErrorOccurrence
GROUP BY ErrorReference HAVING COUNT(*) > 1;

-- counters restarting each day, ticket and error independent
SELECT RefType, RefDate, LastValue FROM ERM.ERM_ReferenceCounter ORDER BY RefDate DESC, RefType;
```

The generator is concurrency-safe by construction (`UPDATE … OUTPUT`, no
read-then-write window) and that is proven against the demo by
`tools/verify-reference-concurrency.mjs` — 120 simultaneous requests, contiguous
`1..120`, no duplicates. **It has not yet been proven against SQL Server**,
because I have no instance; the duplicate query above is how you confirm it on
yours, and it is the highest-value single check in Test.

---

## 5. Promotion checklist — Test to EBS-PROD

Not a date. Move when these are true:

- [ ] All nine required scripts ran clean on Test, ledger complete.
- [ ] `ERM_DeadLetter` empty, or every row understood.
- [ ] No duplicate or malformed reference codes after a period of real load.
- [ ] The recurring-problems report is readable rather than a wall of noise — if
      it is noisy, tune `AutoTicketRule` thresholds and the ignore lists in Test,
      not in PROD.
- [ ] Retention job has run at least once and its `ERM_RetentionRunLog` row
      shows `Succeeded = 1`.
- [ ] A real ticket has been driven end to end: captured → reported → assigned →
      reassigned → waiting → user replied → resolved → closed, with the audit
      trail checked.
- [ ] A normal ERP user has been confirmed to get `403` from the admin API — not
      just a hidden menu item.
- [ ] `fn_SystemUserID` returns your real id, not `0`.
- [ ] `capture.storeRequestBody` / `storeResponseBody` reviewed against what
      your payloads actually contain, and the redaction allow-list extended for
      any field you want kept in full.
- [ ] Sign-off on which optional script, if any, you want (`008` / `009` /
      neither).

For EBS-PROD itself: same scripts, same order, but deploy with
`capture.enabled = false` in `ERM_Setting`, confirm the objects exist and the
grants are right, then switch it on. That way the first thing PROD does with the
framework is nothing, which is the safest possible first action.

---

## 6. Rolling back

The framework is additive. To remove it entirely:

```sql
-- no ERP object depends on anything in here
DROP SCHEMA ERM;   -- after dropping its objects, or script it per object
```

Nothing outside `ERM` needs to change. On the application side, remove the three
lines from `WebApiConfig.Register` and the two from `app.config.ts`; every
screen behaves exactly as it did before, because the framework only ever
observed.

---

## 7. Upgrading later

Scripts are ordered and idempotent, and each records itself in
`ERM.ERM_SchemaVersion`. A future version adds `012_…`, `013_…` rather than
editing an existing script, so an environment can always be brought up to date
by running everything in order again.
