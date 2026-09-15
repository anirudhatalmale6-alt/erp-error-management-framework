using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Erp.ErrorManagement
{
    /// <summary>
    /// The .NET half of the deduplication algorithm.
    ///
    /// This MUST produce the same hash as fingerprint.ts for the same logical
    /// error, otherwise an Angular-reported and an API-reported instance of one
    /// fault open two fingerprints, two tickets and two counts.  The rules are
    /// documented once in docs/ARCHITECTURE.md §6 and implemented twice, here
    /// and there; tools/verify-fingerprint.mjs and FingerprintParityTests assert
    /// the two agree on a shared corpus of signatures.
    /// </summary>
    public static class Fingerprint
    {
        private const RegexOptions Opts = RegexOptions.Compiled | RegexOptions.CultureInvariant;

        private static readonly Regex RxGuid = new Regex(
            @"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", Opts);
        private static readonly Regex RxIsoDate = new Regex(
            @"\b\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?\b", Opts);
        private static readonly Regex RxQuotedSingle = new Regex(@"'[^']*'", Opts);
        private static readonly Regex RxQuotedDouble = new Regex(@"""[^""]*""", Opts);
        private static readonly Regex RxHex = new Regex(@"\b0x[0-9a-fA-F]+\b", Opts);
        private static readonly Regex RxLongHex = new Regex(@"\b[0-9a-fA-F]{16,}\b", Opts);
        private static readonly Regex RxNumber = new Regex(@"\b\d+(\.\d+)?\b", Opts);
        private static readonly Regex RxUrl = new Regex(@"\bhttps?://[^\s)'""]+", Opts);
        private static readonly Regex RxWindowsPath = new Regex(@"\b[a-zA-Z]:\\[^\s:)'""]+", Opts);
        private static readonly Regex RxEmail = new Regex(@"\b[^\s@]+@[^\s@]+\.[^\s@]+\b", Opts);
        private static readonly Regex RxWs = new Regex(@"\s+", Opts);

        /// <summary>Reduce a message to its shape.  Order matters - see the TS twin.</summary>
        public static string NormalizeMessage(string message)
        {
            if (string.IsNullOrEmpty(message)) return string.Empty;

            var s = message;
            s = RxUrl.Replace(s, "{url}");
            s = RxWindowsPath.Replace(s, "{path}");
            s = RxEmail.Replace(s, "{email}");
            s = RxGuid.Replace(s, "{guid}");
            s = RxIsoDate.Replace(s, "{date}");
            s = RxQuotedSingle.Replace(s, "'{str}'");
            s = RxQuotedDouble.Replace(s, "\"{str}\"");
            s = RxHex.Replace(s, "{hex}");
            s = RxLongHex.Replace(s, "{hex}");
            s = RxNumber.Replace(s, "{n}");
            s = RxWs.Replace(s, " ").Trim();

            return s.Length > 500 ? s.Substring(0, 500) : s;
        }

        /// <summary>
        /// Keep the call path, drop the file, line and column.
        ///
        /// A .NET stack frame reads "at Erp.Sales.OrderService.Post(Int32 id) in
        /// C:\build\src\OrderService.cs:line 88".  Everything from " in " is
        /// build-machine detail that changes with every release; the method
        /// signature is the part that identifies the fault.
        /// </summary>
        public static List<string> NormalizeStackFrames(string stackTrace, int depth = 5)
        {
            var frames = new List<string>();
            if (string.IsNullOrEmpty(stackTrace)) return frames;

            foreach (var rawLine in stackTrace.Split('\n'))
            {
                var line = rawLine.Trim();
                if (line.Length == 0) continue;

                if (line.StartsWith("at ", StringComparison.Ordinal)) line = line.Substring(3);
                else if (line.StartsWith("--- End of", StringComparison.Ordinal)) continue;
                else if (!line.Contains("(")) continue;

                var inIndex = line.IndexOf(" in ", StringComparison.Ordinal);
                if (inIndex > 0) line = line.Substring(0, inIndex);

                // Drop the parameter list: an overload resolved differently
                // between builds is still the same fault.
                var paren = line.IndexOf('(');
                if (paren > 0) line = line.Substring(0, paren);

                line = line.Trim();
                if (line.Length == 0) continue;

                // Framework plumbing is identical for every fault and dilutes
                // the signature - the same reason zone.js frames are dropped
                // on the Angular side.
                if (line.StartsWith("System.Runtime.CompilerServices", StringComparison.Ordinal) ||
                    line.StartsWith("System.Threading.Tasks", StringComparison.Ordinal) ||
                    line.StartsWith("System.Runtime.ExceptionServices", StringComparison.Ordinal))
                    continue;

                frames.Add(line);
                if (frames.Count >= depth) break;
            }

            return frames;
        }

        /// <summary>'/api/invoices/4821/lines?page=2' -> '/api/invoices/{id}/lines'</summary>
        public static string NormalizeEndpoint(string endpoint)
        {
            if (string.IsNullOrEmpty(endpoint)) return string.Empty;

            var s = endpoint.Split('?')[0];
            s = RxGuid.Replace(s, "{id}");
            s = Regex.Replace(s, @"/\d+(?=/|$)", "/{id}");
            s = s.TrimEnd('/');
            return s.ToLowerInvariant();
        }

        public class Input
        {
            public string Layer { get; set; }
            public string Category { get; set; }
            public string ExceptionType { get; set; }
            public string Message { get; set; }
            public string StackTrace { get; set; }
            public string Component { get; set; }
            public string Screen { get; set; }
            public string ErpModule { get; set; }
            public string ApiController { get; set; }
            public string ApiAction { get; set; }
            public string ApiEndpoint { get; set; }
            public int? HttpStatusCode { get; set; }
            public int? SqlErrorNumber { get; set; }
            public string SqlObjectName { get; set; }
            public string FormName { get; set; }
            public string LovName { get; set; }
            public IEnumerable<string> ValidationKeys { get; set; }
            public int StackFrameDepth { get; set; } = 5;
        }

        public class Result
        {
            public string Hash { get; set; }
            public string Signature { get; set; }
            public string NormalizedMessage { get; set; }
        }

        private static IEnumerable<string> LocationParts(Input i)
        {
            switch (i.Layer)
            {
                case ErrorLayers.Angular:
                    return new[] { i.ErpModule ?? "", i.Component ?? i.Screen ?? "", i.FormName ?? "", i.LovName ?? "" };
                case ErrorLayers.Http:
                    return new[]
                    {
                        NormalizeEndpoint(i.ApiEndpoint),
                        i.HttpStatusCode.HasValue
                            ? i.HttpStatusCode.Value.ToString(CultureInfo.InvariantCulture)
                            : ""
                    };
                case ErrorLayers.WebApi:
                case ErrorLayers.Business:
                case ErrorLayers.Data:
                    return new[] { i.ApiController ?? "", i.ApiAction ?? "" };
                case ErrorLayers.Database:
                    return new[]
                    {
                        i.SqlErrorNumber.HasValue
                            ? i.SqlErrorNumber.Value.ToString(CultureInfo.InvariantCulture)
                            : "",
                        i.SqlObjectName ?? ""
                    };
                default:
                    return new[] { i.ErpModule ?? "", i.Screen ?? "" };
            }
        }

        public static Result Compute(Input input)
        {
            var normalizedMessage = NormalizeMessage(input.Message);
            var frames = NormalizeStackFrames(input.StackTrace, input.StackFrameDepth);

            var parts = new List<string>
            {
                input.Layer ?? "",
                input.Category ?? "",
                (input.ExceptionType ?? "").Trim(),
                normalizedMessage
            };
            parts.AddRange(LocationParts(input));

            if (input.ValidationKeys != null)
            {
                // Ordinal sort, to match JavaScript's default Array.sort() -
                // which compares UTF-16 code units, NOT the current culture.
                // StringComparer.Ordinal is the equivalent; the default
                // Array.Sort would disagree on any non-ASCII control name.
                parts.AddRange(input.ValidationKeys.OrderBy(k => k, StringComparer.Ordinal));
            }

            parts.AddRange(frames);

            var signature = string.Join("|", parts.Select(p => (p ?? "").Replace("|", "/")));

            return new Result
            {
                Hash = Sha256Hex(signature),
                Signature = signature.Length > 1000 ? signature.Substring(0, 1000) : signature,
                NormalizedMessage = normalizedMessage
            };
        }

        public static string Sha256Hex(string input)
        {
            using (var sha = SHA256.Create())
            {
                var bytes = sha.ComputeHash(Encoding.UTF8.GetBytes(input ?? string.Empty));
                var sb = new StringBuilder(64);
                foreach (var b in bytes) sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
                return sb.ToString();
            }
        }
    }
}
