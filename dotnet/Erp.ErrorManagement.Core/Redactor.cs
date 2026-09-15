using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;

namespace Erp.ErrorManagement
{
    /// <summary>
    /// Server-side twin of redaction.ts.  Allow-list, not deny-list - the
    /// reasoning is in that file and in docs/ARCHITECTURE.md §8.
    ///
    /// Applied at the API boundary as well as in the browser, because the two
    /// see different things: the browser knows the request it sent, the API
    /// knows the model that was bound, the connection string that failed and
    /// the claims on the token.
    /// </summary>
    public class Redactor
    {
        public const string Redacted = "***";

        private static readonly RegexOptions Opts = RegexOptions.Compiled | RegexOptions.CultureInvariant;
        private static readonly Regex RxJwt = new Regex(
            @"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b", Opts);
        private static readonly Regex RxBearer = new Regex(
            @"\bBearer\s+[A-Za-z0-9._~+/=-]{16,}", Opts | RegexOptions.IgnoreCase);
        private static readonly Regex RxBasic = new Regex(
            @"\bBasic\s+[A-Za-z0-9+/=]{16,}", Opts | RegexOptions.IgnoreCase);
        private static readonly Regex RxPan = new Regex(@"\b(?:\d[ -]?){13,19}\b", Opts);

        /// <summary>
        /// Connection strings appear verbatim in the message of almost every
        /// SqlException raised at connect time.  This is the single most common
        /// way a production password ends up in a log file.
        /// </summary>
        private static readonly Regex RxConnectionString = new Regex(
            @"\b(password|pwd|user id|uid|accountkey|sharedaccesskey)\s*=\s*[^;""']+",
            Opts | RegexOptions.IgnoreCase);

        private readonly HashSet<string> _headerAllow;
        private readonly HashSet<string> _payloadAllow;

        public Redactor(IEnumerable<string> headerAllowList, IEnumerable<string> payloadKeyAllowList)
        {
            _headerAllow = new HashSet<string>(
                (headerAllowList ?? Enumerable.Empty<string>()).Select(h => h.ToLowerInvariant()));
            _payloadAllow = new HashSet<string>(
                (payloadKeyAllowList ?? Enumerable.Empty<string>()).Select(k => k.ToLowerInvariant()));
        }

        /// <summary>
        /// Backstop sweep over free text - messages, stack traces, SQL text.
        /// This is the one place a deny-list is right: not as the policy, but as
        /// a net under it.
        /// </summary>
        public static string ScrubText(string value, int maxLength = 4000)
        {
            if (string.IsNullOrEmpty(value)) return value;

            var s = value;
            s = RxJwt.Replace(s, Redacted);
            s = RxBearer.Replace(s, "Bearer " + Redacted);
            s = RxBasic.Replace(s, "Basic " + Redacted);
            s = RxConnectionString.Replace(s, m => m.Groups[1].Value + "=" + Redacted);
            s = RxPan.Replace(s, m => Luhn(m.Value) ? Redacted : m.Value);

            if (s.Length > maxLength)
                s = s.Substring(0, maxLength) + "... [truncated at " + maxLength + " chars]";

            return s;
        }

        /// <summary>
        /// Only mask a long digit run if it checksums as a payment card.  Skip
        /// this and every GL account, document number and phone number in every
        /// message reads '***', which makes the store useless for diagnosis.
        /// </summary>
        private static bool Luhn(string candidate)
        {
            var digits = new string(candidate.Where(char.IsDigit).ToArray());
            if (digits.Length < 13 || digits.Length > 19) return false;

            var sum = 0;
            var alt = false;
            for (var i = digits.Length - 1; i >= 0; i--)
            {
                var n = digits[i] - '0';
                if (alt)
                {
                    n *= 2;
                    if (n > 9) n -= 9;
                }
                sum += n;
                alt = !alt;
            }
            return sum % 10 == 0;
        }

        public Dictionary<string, string> RedactHeaders(IEnumerable<KeyValuePair<string, string>> headers)
        {
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (headers == null) return result;

            foreach (var kv in headers)
            {
                result[kv.Key] = _headerAllow.Contains(kv.Key.ToLowerInvariant())
                    ? ScrubText(kv.Value, 300)
                    : Redacted;
            }
            return result;
        }

        public Dictionary<string, string> RedactQuery(IEnumerable<KeyValuePair<string, string>> query)
        {
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (query == null) return result;

            foreach (var kv in query)
            {
                result[kv.Key] = _payloadAllow.Contains(kv.Key.ToLowerInvariant())
                    ? ScrubText(kv.Value, 200)
                    : Redacted;
            }
            return result;
        }

        /// <summary>
        /// Walk an arbitrary object graph, keeping structure and dropping every
        /// value whose key is not allow-listed.
        /// </summary>
        public object RedactObject(object value, int depth = 0, int maxDepth = 6)
        {
            if (value == null) return null;
            if (depth > maxDepth) return "[max depth]";

            switch (value)
            {
                case string s:
                    return ScrubText(s, 500);
                case DateTime dt:
                    return dt.ToString("o");
                case DateTimeOffset dto:
                    return dto.ToString("o");
                case bool _:
                case byte _: case sbyte _:
                case short _: case ushort _:
                case int _: case uint _:
                case long _: case ulong _:
                case float _: case double _: case decimal _:
                    return value;
                case Guid g:
                    return g.ToString();
            }

            if (value is JToken token) return RedactJson(token, depth, maxDepth);

            if (value is IDictionary dictionary)
            {
                var outDict = new Dictionary<string, object>();
                var n = 0;
                foreach (DictionaryEntry entry in dictionary)
                {
                    if (n++ >= 50) { outDict["[truncated]"] = "additional keys omitted"; break; }
                    var key = Convert.ToString(entry.Key) ?? "";
                    outDict[key] = _payloadAllow.Contains(key.ToLowerInvariant())
                        ? RedactObject(entry.Value, depth + 1, maxDepth)
                        : (IsComplex(entry.Value) ? RedactObject(entry.Value, depth + 1, maxDepth) : (object)Redacted);
                }
                return outDict;
            }

            if (value is IEnumerable enumerable)
            {
                var list = new List<object>();
                var n = 0;
                foreach (var item in enumerable)
                {
                    // Cap hard: an error on a 5,000-row grid save must not write
                    // 5,000 redacted objects into the error store.
                    if (n++ >= 20) { list.Add("[+more items]"); break; }
                    list.Add(RedactObject(item, depth + 1, maxDepth));
                }
                return list;
            }

            // Plain POCO / anonymous type.
            var result = new Dictionary<string, object>();
            foreach (var prop in value.GetType().GetProperties())
            {
                if (!prop.CanRead || prop.GetIndexParameters().Length > 0) continue;

                object propValue;
                try
                {
                    propValue = prop.GetValue(value, null);
                }
                catch
                {
                    // A property getter that throws is common on lazy-loaded EF
                    // proxies and must not take the capture down with it.
                    result[prop.Name] = "[getter threw]";
                    continue;
                }

                result[prop.Name] = _payloadAllow.Contains(prop.Name.ToLowerInvariant())
                    ? RedactObject(propValue, depth + 1, maxDepth)
                    : (IsComplex(propValue) ? RedactObject(propValue, depth + 1, maxDepth) : (object)Redacted);
            }
            return result;
        }

        private object RedactJson(JToken token, int depth, int maxDepth)
        {
            if (depth > maxDepth) return "[max depth]";

            switch (token.Type)
            {
                case JTokenType.Object:
                    var obj = new Dictionary<string, object>();
                    foreach (var prop in ((JObject)token).Properties())
                    {
                        obj[prop.Name] = _payloadAllow.Contains(prop.Name.ToLowerInvariant())
                            ? RedactJson(prop.Value, depth + 1, maxDepth)
                            : (prop.Value.Type == JTokenType.Object || prop.Value.Type == JTokenType.Array
                                ? RedactJson(prop.Value, depth + 1, maxDepth)
                                : (object)Redacted);
                    }
                    return obj;

                case JTokenType.Array:
                    var arr = new List<object>();
                    var n = 0;
                    foreach (var item in (JArray)token)
                    {
                        if (n++ >= 20) { arr.Add("[+more items]"); break; }
                        arr.Add(RedactJson(item, depth + 1, maxDepth));
                    }
                    return arr;

                case JTokenType.String:
                    return ScrubText(token.Value<string>(), 500);

                case JTokenType.Null:
                    return null;

                default:
                    return ((JValue)token).Value;
            }
        }

        private static bool IsComplex(object value)
        {
            if (value == null) return false;
            var t = value.GetType();
            return !(t.IsPrimitive || value is string || value is DateTime || value is DateTimeOffset
                     || value is decimal || value is Guid || t.IsEnum);
        }
    }
}
