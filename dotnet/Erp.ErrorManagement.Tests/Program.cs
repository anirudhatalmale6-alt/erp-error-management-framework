using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.IO;
using System.Linq;
using Erp.ErrorManagement;
using Microsoft.SqlServer.TransactSql.ScriptDom;

namespace Erp.ErrorManagement.Tests
{
    /// <summary>
    /// A plain console runner rather than a test framework, so the client can
    /// run it with a single `dotnet run` on any machine with the .NET SDK and
    /// read the output without installing anything.
    ///
    /// Three things are verified here, and all three are things I would
    /// otherwise only be able to assert:
    ///
    ///   1. Every T-SQL script in db/ parses against the real SQL Server
    ///      grammar (Microsoft's own ScriptDom parser - the one SSMS and
    ///      sqlpackage use).
    ///   2. The C# fingerprint and the TypeScript fingerprint agree, digest for
    ///      digest, on a shared corpus.  If they ever drift, one fault opens two
    ///      tickets and nobody notices for months.
    ///   3. Redaction keeps what it is supposed to keep and drops what it is
    ///      supposed to drop - including a positive control that proves the
    ///      check is capable of failing.
    /// </summary>
    public static class Program
    {
        private static int _failures;
        private static int _checks;

        public static int Main(string[] args)
        {
            var repoRoot = FindRepoRoot();
            Console.WriteLine($"Repository root: {repoRoot}\n");

            RunSqlParseChecks(Path.Combine(repoRoot, "db"));
            RunFingerprintParityChecks(repoRoot);
            RunRedactionChecks();
            RunClassifierChecks();
            RunOrmUnwrapChecks();
            RunThrottleChecks();
            RunEndUserSqlChecks(Path.Combine(repoRoot, "db"));
            RunDynamicSqlChecks(Path.Combine(repoRoot, "db"));
            RunSupportAccessChecks(Path.Combine(repoRoot, "db"), repoRoot);

            Console.WriteLine();
            Console.WriteLine(_failures == 0
                ? $"ALL {_checks} CHECKS PASSED"
                : $"{_failures} of {_checks} CHECKS FAILED");
            return _failures == 0 ? 0 : 1;
        }

        /* ===================================================== SQL parsing == */

        private static void RunSqlParseChecks(string dbFolder)
        {
            Console.WriteLine("=== T-SQL syntax (Microsoft.SqlServer.TransactSql.ScriptDom, SQL 2016 grammar) ===");

            if (!Directory.Exists(dbFolder))
            {
                Fail($"db folder not found at {dbFolder}");
                return;
            }

            var scripts = Directory.GetFiles(dbFolder, "*.sql").OrderBy(f => f).ToList();
            if (scripts.Count == 0) Fail("no .sql scripts found");

            foreach (var script in scripts)
            {
                // TSql130Parser = SQL Server 2016, the oldest version this
                // framework claims to support.  Parsing against the OLDEST
                // supported grammar is the point: a 2019-only construct that
                // parses fine on 160 would fail on the client's server.
                var parser = new TSql130Parser(initialQuotedIdentifiers: true);

                using var reader = new StreamReader(script);
                parser.Parse(reader, out IList<ParseError> errors);

                if (errors is { Count: > 0 })
                {
                    Fail($"{Path.GetFileName(script)} - {errors.Count} parse error(s)");
                    foreach (var e in errors.Take(10))
                        Console.WriteLine($"        line {e.Line}, col {e.Column}: {e.Message}");
                }
                else
                {
                    Pass($"{Path.GetFileName(script)} parses clean against SQL Server 2016 grammar");
                }
            }

            // Positive control: the parser must actually be capable of failing.
            // A "0 errors" result from a parser that silently accepts anything
            // proves nothing at all.
            var control = new TSql130Parser(true);
            using (var bad = new StringReader("SELECT FROM WHERE ORDER BY GROUP;"))
            {
                control.Parse(bad, out IList<ParseError> controlErrors);
                Check("positive control: deliberately broken T-SQL IS rejected",
                    controlErrors is { Count: > 0 }, true);
            }
        }

        /* ============================================== fingerprint parity == */

        /// <summary>
        /// The corpus is a set of (input, expected-hash) pairs.  The expected
        /// hashes are produced by the TypeScript implementation via
        /// tools/verify-fingerprint.mjs; this asserts the C# implementation
        /// lands on the same values.
        /// </summary>
        private static void RunFingerprintParityChecks(string repoRoot)
        {
            Console.WriteLine("\n=== Fingerprint: C# <-> TypeScript parity ===");

            // Known-answer vectors for the hash itself.
            Check("sha256(\"\")", Fingerprint.Sha256Hex(""),
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
            Check("sha256(\"abc\")", Fingerprint.Sha256Hex("abc"),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

            // Normalisation must agree token for token with fingerprint.ts.
            Check("NormalizeMessage strips ids, quotes and dates",
                Fingerprint.NormalizeMessage(
                    "Invoice 40821 for customer 'ACME LTD' failed on 2026-09-15T10:22:31Z"),
                "Invoice {n} for customer '{str}' failed on {date}");

            Check("NormalizeMessage strips guid",
                Fingerprint.NormalizeMessage("Row 3f2504e0-4f89-41d3-9a0c-0305e82c3301 not found"),
                "Row {guid} not found");

            Check("NormalizeEndpoint strips record ids",
                Fingerprint.NormalizeEndpoint("/api/invoices/4821/lines?page=2"),
                "/api/invoices/{id}/lines");

            // The signature layout must match exactly, because the hash is taken
            // over the joined string.  This is the value produced by the
            // TypeScript implementation for the same input.
            var angular = Fingerprint.Compute(new Fingerprint.Input
            {
                Layer = ErrorLayers.Angular,
                Category = "angular_runtime",
                ExceptionType = "TypeError",
                Message = "Cannot read properties of undefined (reading 'total') for order 1001",
                StackTrace = "TypeError: x\n    at OrderComponent.calc (http://erp/main-AAA1.js:1:12)",
                Component = "OrderComponent",
                ErpModule = "SD"
            });

            Check("Angular-layer signature matches the TypeScript twin",
                angular.Signature,
                "angular|angular_runtime|TypeError|Cannot read properties of undefined (reading '{str}') for order {n}|SD|OrderComponent|||OrderComponent.calc");

            Check("Angular-layer HASH matches the TypeScript twin",
                angular.Hash,
                "5259b903931782361c7a7a138acb271b92e59c1f7a7c3ed676d4afaf0e9b5ab8");

            // The property that makes deduplication work at all.
            var a = Fingerprint.Compute(new Fingerprint.Input
            {
                Layer = ErrorLayers.Database, Category = ErrorCategories.SqlDeadlock,
                ExceptionType = "System.Data.SqlClient.SqlException",
                Message = "Transaction (Process ID 71) was deadlocked on lock resources",
                SqlErrorNumber = 1205, SqlObjectName = "usp_PostJournal"
            });
            var b = Fingerprint.Compute(new Fingerprint.Input
            {
                Layer = ErrorLayers.Database, Category = ErrorCategories.SqlDeadlock,
                ExceptionType = "System.Data.SqlClient.SqlException",
                Message = "Transaction (Process ID 143) was deadlocked on lock resources",
                SqlErrorNumber = 1205, SqlObjectName = "usp_PostJournal"
            });
            Check("same deadlock, different SPID -> same fingerprint", a.Hash, b.Hash);

            var c = Fingerprint.Compute(new Fingerprint.Input
            {
                Layer = ErrorLayers.Database, Category = ErrorCategories.SqlDeadlock,
                ExceptionType = "System.Data.SqlClient.SqlException",
                Message = "Transaction (Process ID 71) was deadlocked on lock resources",
                SqlErrorNumber = 1205, SqlObjectName = "usp_PostInvoice"
            });
            Check("same deadlock in a DIFFERENT procedure -> different fingerprint",
                a.Hash == c.Hash, false);

            // .NET stack frames must lose the build path and line number, or
            // every release resets the occurrence counters to zero.
            var withPath = Fingerprint.Compute(new Fingerprint.Input
            {
                Layer = ErrorLayers.WebApi, Category = ErrorCategories.ApiUnhandled,
                ExceptionType = "NullReferenceException", Message = "Object reference not set",
                ApiController = "Orders", ApiAction = "Post",
                StackTrace = "   at Erp.Sales.OrderService.Post(Int32 id) in C:\\build\\v2026.3.1\\src\\OrderService.cs:line 88"
            });
            var otherBuild = Fingerprint.Compute(new Fingerprint.Input
            {
                Layer = ErrorLayers.WebApi, Category = ErrorCategories.ApiUnhandled,
                ExceptionType = "NullReferenceException", Message = "Object reference not set",
                ApiController = "Orders", ApiAction = "Post",
                StackTrace = "   at Erp.Sales.OrderService.Post(Int32 id) in D:\\agent\\_work\\9\\src\\OrderService.cs:line 104"
            });
            Check("same fault, different build path and line -> same fingerprint",
                withPath.Hash, otherBuild.Hash);

            Check("positive control: an obviously different fault differs",
                withPath.Hash == a.Hash, false);
        }

        /* ==================================================== redaction ==== */

        private static void RunRedactionChecks()
        {
            Console.WriteLine("\n=== Redaction (allow-list) ===");

            var redactor = new Redactor(
                headerAllowList: new[] { "content-type", "x-correlation-id" },
                payloadKeyAllowList: new[] { "id", "documentno" });

            var headers = redactor.RedactHeaders(new Dictionary<string, string>
            {
                ["Content-Type"] = "application/json",
                ["Authorization"] = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
                ["Cookie"] = "ASP.NET_SessionId=abc123"
            });

            Check("allow-listed header kept", headers["Content-Type"], "application/json");
            Check("Authorization redacted", headers["Authorization"], Redactor.Redacted);
            Check("Cookie redacted (never on the allow-list)", headers["Cookie"], Redactor.Redacted);

            // The important case: a field NOBODY thought to deny.
            var body = (Dictionary<string, object>)redactor.RedactObject(new
            {
                Id = 4821,
                DocumentNo = "PO-2026-0043",
                IqamaNumber = "2412345678",
                BankIban = "SA0380000000608010167519",
                SecurityAnswer = "my first school"
            });

            Check("allow-listed body key kept", body["Id"], 4821);
            Check("allow-listed document number kept", body["DocumentNo"], "PO-2026-0043");
            Check("unknown PII field 'IqamaNumber' redacted by default", body["IqamaNumber"], Redactor.Redacted);
            Check("unknown 'BankIban' redacted by default", body["BankIban"], Redactor.Redacted);
            Check("unknown 'SecurityAnswer' redacted by default", body["SecurityAnswer"], Redactor.Redacted);

            // Backstop sweep over free text.
            var sqlMessage = "Login failed. Connection string: Server=erp-sql01;Database=ERP;User Id=sa;Password=Sup3rS3cret!;";
            var scrubbed = Redactor.ScrubText(sqlMessage);
            Check("connection-string password scrubbed from a SQL message",
                scrubbed.Contains("Sup3rS3cret"), false);
            Check("...but the server name survives (it is diagnostic, not secret)",
                scrubbed.Contains("erp-sql01"), true);

            Check("card number scrubbed", Redactor.ScrubText("card 4111111111111111 declined").Contains("4111"), false);
            Check("positive control: a document number that is NOT a card survives",
                Redactor.ScrubText("document 4111111111111112 posted").Contains("4111111111111112"), true);
        }

        /* =================================================== classifier ==== */

        private static void RunClassifierChecks()
        {
            Console.WriteLine("\n=== Exception classification ===");

            var timeout = ExceptionClassifier.Classify(new TimeoutException("The operation timed out"));
            Check("TimeoutException -> sql_timeout / 504", timeout.Category, ErrorCategories.SqlTimeout);
            Check("TimeoutException -> HTTP 504", timeout.HttpStatusCode, 504);

            Check("timeout nested inside an AggregateException is still found",
                ExceptionClassifier.FindInChain<TimeoutException>(
                    new InvalidOperationException("outer",
                        new AggregateException(new TimeoutException("inner")))) != null, true);

            var business = ExceptionClassifier.Classify(new CreditLimitBusinessException("over limit"));
            Check("a *BusinessException is a low-severity business rule, not an outage",
                business.Category, ErrorCategories.BusinessRule);
            Check("...and returns 400, not 500", business.HttpStatusCode, 400);

            var unknown = ExceptionClassifier.Classify(new NullReferenceException());
            Check("NullReferenceException stays critical / api_unhandled",
                unknown.Category, ErrorCategories.ApiUnhandled);
            Check("positive control: not everything is classified as a business rule",
                unknown.Category == ErrorCategories.BusinessRule, false);

            // Regression guard for a real defect found while demoing this:
            // deadlock originally mapped to 409, which the Angular default
            // ignore list drops - so the server logged a critical fault and the
            // user saw nothing.  A deadlock is retryable, not a client conflict.
            Check("deadlock maps to 503 (retryable), NOT 409 (client conflict)",
                DeadlockStatus(), 503);
            Check("optimistic concurrency still maps to 409",
                ExceptionClassifier.Classify(new System.Data.DBConcurrencyException("stale")).HttpStatusCode, 409);
            Check("positive control: 409 is genuinely reachable, so the check above can fail",
                ExceptionClassifier.Classify(new System.Data.DBConcurrencyException("x")).HttpStatusCode == 503, false);

            Check("chained unwrap reaches the innermost message",
                ExceptionClassifier.Unwrap(
                    new System.Reflection.TargetInvocationException(
                        new ArgumentException("the real one"))).Message,
                "the real one");
        }

        /// <summary>
        /// SqlException cannot be constructed directly, so the deadlock mapping
        /// is asserted against the same lookup the classifier uses rather than
        /// against a fabricated exception that could not occur in production.
        /// </summary>
        private static int DeadlockStatus()
        {
            // Mirrors ExceptionClassifier.ApplySql's deadlock branch.  Kept in a
            // helper so this test fails loudly if that branch is edited without
            // the reasoning being revisited.
            var source = File.ReadAllText(Path.Combine(FindRepoRoot(),
                "dotnet", "Erp.ErrorManagement.Core", "ExceptionClassifier.cs"));
            var idx = source.IndexOf("if (number == Deadlock)", StringComparison.Ordinal);
            if (idx < 0) return -1;
            var block = source.Substring(idx, Math.Min(1400, source.Length - idx));
            var statusIdx = block.IndexOf("result.HttpStatusCode =", StringComparison.Ordinal);
            if (statusIdx < 0) return -1;
            var value = block.Substring(statusIdx + 23).TrimStart();
            var digits = new string(value.TakeWhile(char.IsDigit).ToArray());
            return int.TryParse(digits, out var parsed) ? parsed : -1;
        }

        /* ============================================ ORM unwrapping ==== */

        /// <summary>
        /// The ERP has three execution paths to the database: EF6 EDMX, a custom
        /// ADO.NET SP executor, and EF Core. Each wraps a SqlException
        /// differently, and a wrapper that is not unwrapped means the captured
        /// exception type is "DbUpdateException" for every database fault in the
        /// system - which fingerprints them all together and makes the whole
        /// store useless for the database layer.
        ///
        /// Stand-ins are used because Core deliberately does not reference EF6
        /// or EF Core, so the real types are not available here - and that is
        /// exactly why the production code matches on the type NAME. Naming the
        /// stand-ins identically is therefore a faithful test of the mechanism.
        /// </summary>
        private class UpdateException : Exception
        {
            public UpdateException(string m, Exception inner) : base(m, inner) { }
        }

        private class DbUpdateException : Exception
        {
            public DbUpdateException(string m, Exception inner) : base(m, inner) { }
        }

        private class EntityCommandExecutionException : Exception
        {
            public EntityCommandExecutionException(string m, Exception inner) : base(m, inner) { }
        }

        private class DbUpdateConcurrencyException : Exception
        {
            public DbUpdateConcurrencyException(string m) : base(m) { }
        }

        private class DbEntityValidationException : Exception
        {
            public DbEntityValidationException(string m) : base(m) { }
        }

        private class NotAWrapperException : Exception
        {
            public NotAWrapperException(string m, Exception inner) : base(m, inner) { }
        }

        private static void RunOrmUnwrapChecks()
        {
            Console.WriteLine("\n=== ORM wrapper unwrapping (EF6 EDMX / EF Core / custom SP executor) ===");

            var root = new InvalidOperationException("the real cause");

            Check("EF6 EDMX UpdateException is unwrapped",
                ExceptionClassifier.Unwrap(new UpdateException("wrapper", root)).Message, "the real cause");
            Check("EF6 DbUpdateException is unwrapped",
                ExceptionClassifier.Unwrap(new DbUpdateException("wrapper", root)).Message, "the real cause");
            Check("EDMX EntityCommandExecutionException is unwrapped",
                ExceptionClassifier.Unwrap(new EntityCommandExecutionException("wrapper", root)).Message,
                "the real cause");

            // Nested two deep, which is what an EDMX SaveChanges over a failing
            // proc actually produces.
            Check("nested EDMX wrappers unwrap all the way down",
                ExceptionClassifier.Unwrap(
                    new DbUpdateException("outer", new UpdateException("inner", root))).Message,
                "the real cause");

            // POSITIVE CONTROL: an exception that merely HAS an inner exception
            // must NOT be unwrapped, or the classifier would discard the
            // application's own exception type on every wrapped business error.
            Check("positive control: a non-wrapper exception is NOT unwrapped",
                ExceptionClassifier.Unwrap(new NotAWrapperException("keep me", root)).Message, "keep me");

            // Concurrency and validation survive Unwrap (no inner exception) and
            // must still classify correctly rather than falling through to
            // "unhandled .NET exception / critical".
            var conc = ExceptionClassifier.Classify(new DbUpdateConcurrencyException("row vanished"));
            Check("DbUpdateConcurrencyException -> concurrency", conc.Category, ErrorCategories.Concurrency);
            Check("DbUpdateConcurrencyException -> 409", conc.HttpStatusCode, 409);

            var val = ExceptionClassifier.Classify(new DbEntityValidationException("Validation failed"));
            Check("DbEntityValidationException -> business_rule", val.Category, ErrorCategories.BusinessRule);
            Check("DbEntityValidationException -> 400, not 500", val.HttpStatusCode, 400);
            Check("positive control: it is NOT treated as critical",
                val.Severity == ErrorSeverities.Critical, false);
        }

        /* ============================================ throttle ========== */

        private static void RunThrottleChecks()
        {
            Console.WriteLine("\n=== Anonymous capture throttle ===");

            // burst 5, 60/min. The first 5 go through; the 6th does not.
            var throttle = new AnonymousCaptureThrottle(envelopesPerMinute: 60, burst: 5);

            Check("first request within burst is granted", throttle.TryAcquire("10.0.0.1", 1), 1);
            Check("remaining burst is granted", throttle.TryAcquire("10.0.0.1", 4), 4);
            Check("burst exhausted -> 0 granted", throttle.TryAcquire("10.0.0.1", 1), 0);

            // A different client is unaffected - the limit is per client, not
            // global, or one noisy IP would silence capture for everyone.
            Check("a different client IP has its own bucket", throttle.TryAcquire("10.0.0.2", 5), 5);

            // PARTIAL grant: a batch of 10 against 5 remaining tokens must
            // accept 5, not reject all 10. Rejecting the batch would throw away
            // evidence the framework had already received.
            var partial = new AnonymousCaptureThrottle(envelopesPerMinute: 60, burst: 5);
            Check("a batch larger than the bucket is PARTIALLY granted",
                partial.TryAcquire("10.0.0.3", 10), 5);

            Check("zero-count request grants nothing", throttle.TryAcquire("10.0.0.1", 0), 0);
            Check("null/blank client key does not throw", throttle.TryAcquire(null, 1) >= 0, true);

            // POSITIVE CONTROL: the limiter must be capable of granting, or
            // "0 granted" above would prove nothing.
            var fresh = new AnonymousCaptureThrottle(envelopesPerMinute: 600, burst: 50);
            Check("positive control: a fresh generous bucket DOES grant", fresh.TryAcquire("10.0.0.9", 50), 50);
        }

        /* ==================================== end-user SQL guarantees === */

        /// <summary>
        /// The end-user ticket procedures carry a security property that cannot
        /// be checked by parsing alone: every read path must be gated by the
        /// ownership function. These are structural assertions over the script -
        /// crude, but they fail loudly if someone later adds an end-user read
        /// path and forgets the check, which is the mistake worth catching.
        /// </summary>
        private static void RunEndUserSqlChecks(string dbFolder)
        {
            Console.WriteLine("\n=== End-user ticket access: ownership enforced in SQL ===");

            var path = Path.Combine(dbFolder, "007_end_user_ticket_access.sql");
            if (!File.Exists(path)) { Fail("007_end_user_ticket_access.sql not found"); return; }

            // Comments are STRIPPED before asserting anything.
            //
            // The first version of this check matched raw text and "failed"
            // because the script contains a comment listing the fields it
            // deliberately does not select. An assertion that cannot tell a
            // comment from a statement is worse than no assertion: it fires on
            // documentation and would stay silent on a real leak buried in a
            // commented block.
            var sql = StripSqlComments(File.ReadAllText(path));

            Check("ownership predicate exists", sql.Contains("fn_UserOwnsTicket"), true);

            var ownsFn = Section(sql, "FUNCTION erp_err.fn_UserOwnsTicket");
            Check("an anonymous caller owns nothing",
                ownsFn.Contains("@UserId IS NULL AND @UserName IS NULL") && ownsFn.Contains("RETURN 0"),
                true);

            var getForUser = Section(sql, "PROCEDURE erp_err.usp_Ticket_GetForUser");
            var addComment = Section(sql, "PROCEDURE erp_err.usp_Ticket_AddUserComment");

            Check("usp_Ticket_GetForUser gates on the ownership check",
                getForUser.Contains("fn_UserOwnsTicket"), true);
            Check("usp_Ticket_AddUserComment gates on the ownership check",
                addComment.Contains("fn_UserOwnsTicket"), true);
            Check("a closed ticket cannot be commented on",
                addComment.Contains("IsTerminal"), true);

            // Internal fields must not reach the end user. Asserted as absence
            // from the executable text, which is now meaningful.
            foreach (var leak in new[] { "AssignedToUserName", "FingerprintId",
                                         "SlaFirstResponseBreached", "SlaResolutionBreached",
                                         "ActiveProcessingMinutes", "TotalElapsedMinutes",
                                         "ChangedByUserName", "ReopenCount" })
            {
                Check($"end-user view does not expose {leak}", getForUser.Contains(leak), false);
            }

            // POSITIVE CONTROL: the stripper must not have removed everything -
            // otherwise every "does not expose" check above passes trivially.
            Check("positive control: the end-user view DOES select its own fields",
                getForUser.Contains("TicketNumber") && getForUser.Contains("StatusName")
                    && getForUser.Contains("ResolutionNotes"), true);

            // POSITIVE CONTROL: the stripper must be capable of finding a leak.
            Check("positive control: the stripper finds a field that IS present",
                getForUser.Contains("ErrorReference"), true);
        }

        /* ================================= dynamic SQL ================== */

        /// <summary>
        /// Parse the SQL that the dynamic procedures actually BUILD, not just
        /// the script that builds it.
        ///
        /// This matters more than it sounds. ScriptDom parsing 010 only proves
        /// the wrapper is valid T-SQL - the query inside the string literal is,
        /// to the parser, just text. A missing comma or an unbalanced
        /// parenthesis in there compiles fine and fails at runtime, on the
        /// support console, in production.
        ///
        /// So: reassemble each @sql expression the way SQL Server would, for
        /// every combination of the branches it contains, substitute a real
        /// whitelisted ORDER BY clause, and parse each result.
        /// </summary>
        private static void RunDynamicSqlChecks(string dbFolder)
        {
            Console.WriteLine("\n=== Dynamic SQL: parse what the procedures actually BUILD ===");

            var path = Path.Combine(dbFolder, "010_search_performance.sql");
            if (!File.Exists(path)) { Fail("010_search_performance.sql not found"); return; }

            var raw = File.ReadAllText(path);
            var sql = StripSqlComments(raw);

            // A real ORDER BY clause from the whitelist in the same script, so
            // the substitution is representative rather than invented.
            const string orderBy = "o.OccurredUtc DESC, o.OccurrenceId DESC";

            var procs = new[]
            {
                "PROCEDURE erp_err.usp_Error_Search",
                "PROCEDURE erp_err.usp_Ticket_Search",
                "PROCEDURE erp_err.usp_Error_RecurringProblems",
            };

            var totalVariants = 0;

            foreach (var proc in procs)
            {
                var body = Section(sql, proc);
                if (body.Length == 0) { Fail($"{proc} not found"); continue; }

                var expr = ExtractSqlAssignment(body);
                if (expr == null) { Fail($"{proc} - could not locate the @sql assignment"); continue; }

                var variants = ExpandBranches(expr);
                if (variants.Count == 0) { Fail($"{proc} - no variants produced"); continue; }

                var name = proc.Substring(proc.LastIndexOf('.') + 1);
                var bad = 0;

                foreach (var v in variants)
                {
                    var built = EvaluateConcat(v).Replace("@orderBy", orderBy);
                    totalVariants++;

                    var parser = new TSql130Parser(true);
                    using var reader = new StringReader(built);
                    parser.Parse(reader, out IList<ParseError> errors);

                    if (errors is { Count: > 0 })
                    {
                        bad++;
                        Console.WriteLine($"        {errors[0].Message} (line {errors[0].Line})");
                    }
                }

                Check($"{name}: all {variants.Count} generated variants parse", bad, 0);
            }

            Check($"positive control: variants were actually generated and parsed", totalVariants > 0, true);

            // The security property of the whole approach: the caller's sort
            // value must never reach the SQL text. It is a lookup key only.
            var searchBody = Section(sql, "PROCEDURE erp_err.usp_Error_Search");
            Check("@SortBy is never concatenated into the SQL text",
                searchBody.Contains("+ @SortBy") || searchBody.Contains("@SortBy +"), false);
            Check("...it is resolved through the whitelist instead",
                searchBody.Contains("fn_ResolveSort"), true);

            // Every value must travel as a parameter.
            Check("usp_Error_Search passes values via sp_executesql parameters",
                searchBody.Contains("sp_executesql") && searchBody.Contains("@SearchText NVARCHAR(200)"), true);

            // The defect this script exists to fix: no per-row correlated count.
            var recurring = Section(sql, "PROCEDURE erp_err.usp_Error_RecurringProblems");
            Check("recurring problems no longer counts per fingerprint row",
                recurring.Contains("CROSS APPLY"), false);
            Check("...it aggregates the window once, with HAVING",
                recurring.Contains("GROUP BY o.FingerprintId") && recurring.Contains("HAVING COUNT_BIG(*)"), true);

            // Bounded reads.
            var trail = Section(sql, "PROCEDURE erp_err.usp_Error_GetCorrelationTrail");
            Check("correlation trail is bounded by TOP (@MaxRows)",
                trail.Contains("TOP (@MaxRows)"), true);
            Check("...and reports the true total so truncation is visible",
                trail.Contains("TotalInTrail"), true);

            // Every whitelisted sort must end in a unique tiebreaker, or rows
            // shuffle between pages and pagination appears to lose records.
            var whitelistBlock = sql.Substring(sql.IndexOf("USING (VALUES", StringComparison.Ordinal));
            whitelistBlock = whitelistBlock.Substring(0, whitelistBlock.IndexOf(") AS s (ListName", StringComparison.Ordinal));
            var clauses = System.Text.RegularExpressions.Regex.Matches(
                whitelistBlock, @"N'((?:o|t|f|w|sv|st|q|l)\.[^']*)'");
            var noTiebreak = clauses
                .Select(m => m.Groups[1].Value)
                .Where(c => !c.Contains("OccurrenceId") && !c.Contains("TicketId") && !c.Contains("FingerprintId"))
                .ToList();
            Check("every whitelisted sort ends with a unique tiebreaker",
                noTiebreak.Count == 0 ? "none missing" : string.Join(" | ", noTiebreak),
                "none missing");
            Check("positive control: sort clauses were actually found", clauses.Count > 0, true);
        }

        /* ======================== support access / manual tickets ======= */

        /// <summary>
        /// Structural guarantees for admin access and manual tickets.
        ///
        /// These are assertions about SHAPE, not behaviour - the behaviour
        /// needs a running SQL Server. They exist to catch the specific
        /// mistakes that are easy to make later: adding an admin endpoint
        /// without a capability attribute, letting the authorisation check fail
        /// open, or letting a client supply the ticket owner.
        /// </summary>
        private static void RunSupportAccessChecks(string dbFolder, string repoRoot)
        {
            Console.WriteLine("\n=== Support access, assignment audit, manual tickets ===");

            var path = Path.Combine(dbFolder, "011_support_access_and_manual_tickets.sql");
            if (!File.Exists(path)) { Fail("011 not found"); return; }

            var sql = StripSqlComments(File.ReadAllText(path));

            // --- authorisation fails closed --------------------------------
            var cap = Section(sql, "FUNCTION erp_err.fn_SupportCapability");
            Check("capability check exists", cap.Length > 0, true);
            Check("no identity -> no capability (fails closed)",
                cap.Contains("@UserId IS NULL AND @UserName IS NULL") && cap.Contains("RETURN 0"), true);
            Check("an unknown capability name grants nothing",
                cap.Contains("ELSE CONVERT(BIT, 0)"), true);
            Check("only ACTIVE roster rows and ACTIVE roles count",
                cap.Contains("su.IsActive = 1") && cap.Contains("r.IsActive = 1"), true);

            // --- assignment is validated and audited ----------------------
            var assign = Section(sql, "PROCEDURE erp_err.usp_Ticket_Assign");
            Check("assignment requires the 'manage' capability",
                assign.Contains("fn_SupportCapability") && assign.Contains("N'manage'"), true);
            Check("the assignee is validated against the roster",
                assign.Contains("CanBeAssigned = 1"), true);
            Check("assignment writes a history row",
                assign.Contains("INSERT erp_err.TicketStatusHistory"), true);
            Check("...recording WHO it was assigned to",
                assign.Contains("@targetName"), true);
            Check("...and who it was taken FROM, so reassignment is auditable",
                assign.Contains("@PrevAssignee"), true);
            Check("the assignment row is marked as an assignment, not a transition",
                assign.Contains("N'assignment'"), true);
            // A reassignment is not a status change, so it must not be recorded
            // as one - that would corrupt the minutes-in-status accounting.
            Check("the assignment row does NOT fabricate a status transition",
                assign.Contains("@StatusId, @StatusId"), true);
            Check("assignment detail is internal, not shown to the end user",
                assign.Contains("N'assignment')"), true);

            // --- manual tickets -------------------------------------------
            var manual = Section(sql, "PROCEDURE erp_err.usp_Ticket_CreateManual");
            // Asserted on the VALUES list, not on the inline comment next to it -
            // StripSqlComments removes the comment, so matching "1 /*new*/"
            // could never succeed. OccurrenceId and FingerprintId are both NULL.
            Check("a manual ticket has no occurrence and no fingerprint",
                manual.Contains("@TicketNumber, NULL, NULL,"), true);
            Check("a manual ticket must have an owner",
                manual.Contains("A manual ticket must have an owner"), true);
            Check("severity comes from the CATEGORY, not the caller's wish",
                manual.Contains("DefaultSeverityId FROM erp_err.RequestCategory"), true);
            Check("manual tickets are marked as such", manual.Contains("N'manual'"), true);

            Check("Ticket.FingerprintId is relaxed to NULL for manual tickets",
                sql.Contains("ALTER COLUMN FingerprintId BIGINT NULL"), true);
            Check("a CHECK constraint stops a ticket being neither error nor manual",
                sql.Contains("CK_Ticket_SourceIntegrity"), true);

            // POSITIVE CONTROL: the section reader must actually be finding
            // text, or every Contains() above passes vacuously.
            Check("positive control: sections were located, not empty",
                cap.Length > 100 && assign.Length > 100 && manual.Length > 100, true);
            Check("positive control: a string that is NOT in 011 is not found",
                sql.Contains("usp_ThisProcedureDoesNotExist"), false);

            // --- the production API gates every admin action ---------------
            var adminPath = Path.Combine(repoRoot, "dotnet", "Erp.ErrorManagement.WebApi2",
                "AdminController.cs");
            if (!File.Exists(adminPath)) { Fail("AdminController.cs not found"); return; }

            var admin = File.ReadAllText(adminPath);
            var routes = System.Text.RegularExpressions.Regex.Matches(admin, @"\[Http(Get|Post)");
            Check("the admin controller has routes to protect", routes.Count > 0, true);

            // Every action must be covered: either the controller-level
            // attribute or its own. Counting attributes is crude but it fails
            // loudly if someone adds an endpoint and forgets the gate.
            var gates = System.Text.RegularExpressions.Regex.Matches(admin, @"\[RequiresSupport\(");
            Check("every admin action carries a capability gate",
                gates.Count >= routes.Count, true);

            var filterPath = Path.Combine(repoRoot, "dotnet", "Erp.ErrorManagement.WebApi2",
                "ErpAdminAuthorizationFilter.cs");
            var filter = File.ReadAllText(filterPath);
            Check("the filter 401s an unauthenticated caller",
                filter.Contains("HttpStatusCode.Unauthorized"), true);
            Check("the filter 403s an authenticated non-support caller",
                filter.Contains("HttpStatusCode.Forbidden"), true);
            Check("a role-claim lookup failure fails CLOSED",
                filter.Contains("// Fail closed, as above.") && filter.Contains("return false;"), true);

            // The audit trail is worthless if the client can say who acted.
            Check("the API takes the acting user from the token, not the body",
                admin.Contains("me.UserId") && admin.Contains("me.UserName"), true);
            Check("AssignRequest does not accept a 'changed by' field",
                admin.Contains("ChangedBy"), false);

            var userCtl = File.ReadAllText(Path.Combine(repoRoot, "dotnet",
                "Erp.ErrorManagement.WebApi2", "ErrorManagementController.cs"));
            Check("manual-ticket ownership is set from the token",
                userCtl.Contains("request.ReportedByUserId = ctx?.UserId"), true);

            var core = File.ReadAllText(Path.Combine(repoRoot, "dotnet",
                "Erp.ErrorManagement.Core", "SqlErrorStore.cs"));
            Check("...and a client cannot send it (JsonIgnore on the owner fields)",
                core.Contains("[JsonIgnore] public string ReportedByUserId"), true);

            var dir = File.ReadAllText(Path.Combine(repoRoot, "dotnet",
                "Erp.ErrorManagement.Core", "SupportAuthorization.cs"));
            Check("identity resolution returns Anonymous on failure (fails closed)",
                dir.Contains("return SupportIdentity.Anonymous;"), true);
            Check("SupportIdentity.Has() denies everything for a non-support user",
                dir.Contains("if (!IsSupportUser) return false;"), true);
        }

        /// <summary>Locate the `DECLARE @sql NVARCHAR(MAX) = ...;` expression text.</summary>
        private static string ExtractSqlAssignment(string body)
        {
            var i = body.IndexOf("DECLARE @sql NVARCHAR(MAX) =", StringComparison.Ordinal);
            if (i < 0) return null;
            i += "DECLARE @sql NVARCHAR(MAX) =".Length;

            // Ends at the first semicolon that is not inside a string literal.
            var inString = false;
            for (var j = i; j < body.Length; j++)
            {
                if (body[j] == '\'')
                {
                    // '' inside a literal is an escaped quote, not a terminator.
                    if (inString && j + 1 < body.Length && body[j + 1] == '\'') { j++; continue; }
                    inString = !inString;
                }
                else if (body[j] == ';' && !inString)
                {
                    return body.Substring(i, j - i);
                }
            }
            return null;
        }

        /// <summary>
        /// Expand every SCAFFOLDING `CASE WHEN ... THEN N'a' ELSE N'b' END`
        /// into both of its outcomes, so each branch combination is parsed
        /// rather than only the one that happens to run first.
        ///
        /// Must be literal-aware. The first version searched the raw text for
        /// "CASE WHEN" and found the one inside the SELECT list of
        /// usp_Ticket_Search - a CASE that is part of the SQL *text*, not of the
        /// concatenation - then tore it in half and reported four parse
        /// failures that did not exist. A test that cannot tell a string
        /// literal from surrounding code produces exactly the kind of false
        /// alarm that gets a suite ignored.
        /// </summary>
        private static List<string> ExpandBranches(string expr)
        {
            var results = new List<string> { expr };

            for (var guard = 0; guard < 8; guard++)
            {
                var next = new List<string>();
                var expanded = false;

                foreach (var e in results)
                {
                    var start = IndexOfOutsideLiteral(e, "CASE WHEN", 0);
                    if (start < 0) { next.Add(e); continue; }

                    var end = IndexOfOutsideLiteral(e, " END", start);
                    if (end < 0) { next.Add(e); continue; }

                    var caseExpr = e.Substring(start, end + 4 - start);
                    var thenIdx = IndexOfOutsideLiteral(caseExpr, "THEN", 0);
                    var elseIdx = IndexOfOutsideLiteral(caseExpr, "ELSE", 0);
                    if (thenIdx < 0 || elseIdx < 0) { next.Add(e); continue; }

                    var thenPart = caseExpr.Substring(thenIdx + 4, elseIdx - thenIdx - 4).Trim();
                    var elsePart = caseExpr.Substring(elseIdx + 4, caseExpr.Length - elseIdx - 4 - 4).Trim();

                    next.Add(e.Substring(0, start) + thenPart + e.Substring(end + 4));
                    next.Add(e.Substring(0, start) + elsePart + e.Substring(end + 4));
                    expanded = true;
                }

                results = next;
                if (!expanded) break;
            }

            return results;
        }

        /// <summary>
        /// IndexOf that skips anything inside a single-quoted T-SQL literal,
        /// honouring '' as an escaped quote.
        /// </summary>
        private static int IndexOfOutsideLiteral(string text, string needle, int from)
        {
            var inString = false;

            for (var i = from; i < text.Length; i++)
            {
                if (text[i] == '\'')
                {
                    if (inString && i + 1 < text.Length && text[i + 1] == '\'') { i++; continue; }
                    inString = !inString;
                    continue;
                }

                if (!inString
                    && i + needle.Length <= text.Length
                    && string.CompareOrdinal(text, i, needle, 0, needle.Length) == 0)
                {
                    return i;
                }
            }

            return -1;
        }

        /// <summary>
        /// Evaluate a `N'a' + N'b' + @var` concatenation into the string SQL
        /// Server would produce: literals un-escaped, variables left in place
        /// for the caller to substitute.
        /// </summary>
        private static string EvaluateConcat(string expr)
        {
            var sb = new System.Text.StringBuilder();
            var i = 0;

            while (i < expr.Length)
            {
                // N'...' or '...'
                if (expr[i] == '\'' || (expr[i] == 'N' && i + 1 < expr.Length && expr[i + 1] == '\''))
                {
                    var q = expr[i] == 'N' ? i + 1 : i;
                    var j = q + 1;
                    while (j < expr.Length)
                    {
                        if (expr[j] == '\'')
                        {
                            if (j + 1 < expr.Length && expr[j + 1] == '\'') { sb.Append('\''); j += 2; continue; }
                            break;
                        }
                        sb.Append(expr[j]);
                        j++;
                    }
                    i = j + 1;
                    continue;
                }

                // @variable - keep the token so it can be substituted
                if (expr[i] == '@')
                {
                    var j = i;
                    while (j < expr.Length && (char.IsLetterOrDigit(expr[j]) || expr[j] == '@' || expr[j] == '_')) j++;
                    sb.Append(expr.Substring(i, j - i));
                    i = j;
                    continue;
                }

                i++;   // whitespace and '+' between terms
            }

            return sb.ToString();
        }

        /// <summary>
        /// Remove -- line comments and /* block comments */ so an assertion
        /// about what a script DOES cannot be satisfied or defeated by what the
        /// script SAYS. Nested block comments are handled because T-SQL allows
        /// them and this file uses them.
        /// </summary>
        private static string StripSqlComments(string sql)
        {
            var sb = new System.Text.StringBuilder(sql.Length);
            var depth = 0;
            var i = 0;

            while (i < sql.Length)
            {
                if (depth == 0 && i + 1 < sql.Length && sql[i] == '-' && sql[i + 1] == '-')
                {
                    while (i < sql.Length && sql[i] != '\n') i++;
                    continue;
                }

                if (i + 1 < sql.Length && sql[i] == '/' && sql[i + 1] == '*')
                {
                    depth++;
                    i += 2;
                    continue;
                }

                if (depth > 0 && i + 1 < sql.Length && sql[i] == '*' && sql[i + 1] == '/')
                {
                    depth--;
                    i += 2;
                    continue;
                }

                if (depth == 0) sb.Append(sql[i]);
                i++;
            }

            return sb.ToString();
        }

        /// <summary>
        /// The body of one CREATE OR ALTER object: from its declaration to the
        /// next one, or to the end of the script.
        /// </summary>
        private static string Section(string sql, string declaration)
        {
            var start = sql.IndexOf(declaration, StringComparison.Ordinal);
            if (start < 0) return string.Empty;

            var nextFn = sql.IndexOf("CREATE OR ALTER", start + declaration.Length, StringComparison.Ordinal);
            var end = nextFn < 0 ? sql.Length : nextFn;
            return sql.Substring(start, end - start);
        }

        private class CreditLimitBusinessException : Exception
        {
            public CreditLimitBusinessException(string message) : base(message) { }
        }

        /* ======================================================= harness === */

        private static void Check<T>(string name, T actual, T expected)
        {
            _checks++;
            if (Equals(actual, expected)) { Console.WriteLine($"  PASS  {name}"); return; }
            _failures++;
            Console.WriteLine($"  FAIL  {name}");
            Console.WriteLine($"        expected: {expected}");
            Console.WriteLine($"        actual:   {actual}");
        }

        private static void Pass(string name) { _checks++; Console.WriteLine($"  PASS  {name}"); }
        private static void Fail(string name) { _checks++; _failures++; Console.WriteLine($"  FAIL  {name}"); }

        private static string FindRepoRoot()
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "db")))
                dir = dir.Parent;
            return dir?.FullName ?? Directory.GetCurrentDirectory();
        }
    }
}
