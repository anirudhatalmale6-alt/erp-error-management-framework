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
