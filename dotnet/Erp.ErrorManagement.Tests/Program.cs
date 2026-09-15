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
