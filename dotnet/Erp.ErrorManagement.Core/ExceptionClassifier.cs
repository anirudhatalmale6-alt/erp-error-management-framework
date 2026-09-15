using System;
using System.Collections.Generic;
using System.Data;
using System.Data.Common;
using System.Data.SqlClient;
using System.Text;

namespace Erp.ErrorManagement
{
    /// <summary>
    /// Works out which layer an exception really came from, how bad it is, and
    /// pulls the SQL diagnostics out of it.
    ///
    /// The single most valuable thing in this file is the SqlException handling.
    /// The brief asks for "SQL procedure/query information where appropriate"
    /// and for stored-procedure errors to be captured - WITHOUT editing the
    /// existing stored procedures.  That turns out to be free: when a procedure
    /// raises an error, ADO.NET surfaces a SqlException whose Errors collection
    /// already carries Procedure, LineNumber, Number, Class, State and Server.
    /// So the entire database layer is instrumented by reading an exception
    /// that was always there - no TRY/CATCH added to a single proc, no trigger,
    /// no CLR, no Extended Events session required.
    ///
    /// (Errors handled INSIDE a procedure's own TRY/CATCH and swallowed there
    /// are the one exception: nothing outside the procedure can see them.  That
    /// limitation is called out in docs/ARCHITECTURE.md §5.3 with the optional
    /// Extended Events fallback for shops that need it.)
    /// </summary>
    public static class ExceptionClassifier
    {
        public class Classification
        {
            public string Layer { get; set; }
            public string Category { get; set; }
            public string Severity { get; set; }
            public string ExceptionType { get; set; }
            public string Message { get; set; }
            public SqlErrorInfo Sql { get; set; }
            /// <summary>Suggested HTTP status for the response the user's browser gets.</summary>
            public int HttpStatusCode { get; set; } = 500;
        }

        // SQL Server error numbers worth treating specially.
        private const int Deadlock = 1205;
        private const int Timeout = -2;
        private const int LoginFailed = 18456;
        private const int CannotOpenDatabase = 4060;
        private const int ServerNotFound = 53;
        private const int TransportError = 233;
        private const int ConnectionForciblyClosed = 10054;
        private const int NetworkPathNotFound = 121;

        private static readonly HashSet<int> ConstraintErrors = new HashSet<int>
        {
            515,   // cannot insert NULL
            547,   // FK / CHECK constraint
            2601,  // duplicate key on unique index
            2627,  // duplicate key on PK/unique constraint
            8152,  // string or binary data would be truncated (pre-2019 wording)
            2628   // string or binary data would be truncated, with column name
        };

        private static readonly HashSet<int> ConnectionErrors = new HashSet<int>
        {
            LoginFailed, CannotOpenDatabase, ServerNotFound, TransportError,
            ConnectionForciblyClosed, NetworkPathNotFound, 4064, 40613, 10060, 10061, 258
        };

        public static Classification Classify(Exception exception)
        {
            var ex = Unwrap(exception);
            var result = new Classification
            {
                ExceptionType = ex.GetType().FullName,
                Message = ex.Message,
                Layer = ErrorLayers.WebApi,
                Category = ErrorCategories.ApiUnhandled,
                Severity = ErrorSeverities.Critical,
                HttpStatusCode = 500
            };

            var sqlEx = FindInChain<SqlException>(exception);
            if (sqlEx != null)
            {
                ApplySql(result, sqlEx);
                return result;
            }

            // A DbException that is not a SqlException (ODBC, OLE DB, an EF
            // provider wrapper) is still a database-layer fault.
            var dbEx = FindInChain<DbException>(exception);
            if (dbEx != null)
            {
                result.Layer = ErrorLayers.Database;
                result.Category = ErrorCategories.SqlError;
                result.Severity = ErrorSeverities.Critical;
                return result;
            }

            switch (ex)
            {
                case TimeoutException _:
                    result.Layer = ErrorLayers.Data;
                    result.Category = ErrorCategories.SqlTimeout;
                    result.Severity = ErrorSeverities.High;
                    result.HttpStatusCode = 504;
                    return result;

                case DBConcurrencyException _:
                    result.Layer = ErrorLayers.Data;
                    result.Category = ErrorCategories.Concurrency;
                    result.Severity = ErrorSeverities.Medium;
                    result.HttpStatusCode = 409;
                    return result;

                case UnauthorizedAccessException _:
                    result.Layer = ErrorLayers.Business;
                    result.Category = ErrorCategories.Auth;
                    result.Severity = ErrorSeverities.Medium;
                    result.HttpStatusCode = 403;
                    return result;

                case OperationCanceledException _:
                    // The client went away.  Real, but not an incident.
                    result.Layer = ErrorLayers.Http;
                    result.Category = ErrorCategories.Unclassified;
                    result.Severity = ErrorSeverities.Info;
                    result.HttpStatusCode = 499;
                    return result;

                case NotSupportedException _:
                case InvalidOperationException _:
                    result.Layer = ErrorLayers.Business;
                    result.Category = ErrorCategories.BusinessRule;
                    result.Severity = ErrorSeverities.High;
                    return result;

                case FormatException _:
                case ArgumentException _:
                    result.Layer = ErrorLayers.WebApi;
                    result.Category = ErrorCategories.Serialization;
                    result.Severity = ErrorSeverities.Medium;
                    result.HttpStatusCode = 400;
                    return result;
            }

            // The host application's own business exception base type, if it
            // has one, is recognised by convention rather than by reference -
            // Core must not take a dependency on the ERP's assemblies.
            var typeName = ex.GetType().Name;
            if (typeName.EndsWith("BusinessException", StringComparison.OrdinalIgnoreCase) ||
                typeName.EndsWith("ValidationException", StringComparison.OrdinalIgnoreCase) ||
                typeName.EndsWith("RuleException", StringComparison.OrdinalIgnoreCase))
            {
                result.Layer = ErrorLayers.Business;
                result.Category = ErrorCategories.BusinessRule;
                result.Severity = ErrorSeverities.Low;
                result.HttpStatusCode = 400;
                return result;
            }

            if (typeName.IndexOf("Configuration", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                result.Layer = ErrorLayers.Infrastructure;
                result.Category = ErrorCategories.Configuration;
                result.Severity = ErrorSeverities.Critical;
                return result;
            }

            return result;
        }

        private static void ApplySql(Classification result, SqlException sqlEx)
        {
            result.Layer = ErrorLayers.Database;
            result.ExceptionType = "System.Data.SqlClient.SqlException";
            result.Message = sqlEx.Message;

            // Take the FIRST error in the collection: when a procedure calls a
            // procedure that raises, SqlException.Number reports the outermost
            // error but Errors[0] is the one that actually fired, with the
            // procedure name and line that a developer needs.
            SqlError primary = null;
            if (sqlEx.Errors != null && sqlEx.Errors.Count > 0) primary = sqlEx.Errors[0];

            var number = primary?.Number ?? sqlEx.Number;
            var procedure = primary?.Procedure;
            if (string.IsNullOrWhiteSpace(procedure)) procedure = null;

            result.Sql = new SqlErrorInfo
            {
                Number = number,
                Severity = (byte?)(primary?.Class ?? sqlEx.Class),
                State = (byte?)(primary?.State ?? sqlEx.State),
                ObjectName = procedure,
                LineNumber = primary?.LineNumber ?? sqlEx.LineNumber,
                ServerName = primary?.Server ?? sqlEx.Server
            };

            if (number == Deadlock)
            {
                result.Category = ErrorCategories.SqlDeadlock;
                result.Severity = ErrorSeverities.High;
                // 503, NOT 409.
                //
                // 409 is the right status for an optimistic-concurrency
                // conflict: the client holds stale data and the screen shows
                // its own "this record changed" message.  Browser-side capture
                // ignores 409 for exactly that reason.
                //
                // A deadlock victim is a different thing entirely - the client
                // did nothing wrong and the correct advice is "retry".  Sending
                // it as 409 would have it silently filtered by the front-end
                // ignore list, so the user would see nothing at all while the
                // server logged a critical fault.  503 is retryable, visible,
                // and honest.
                result.HttpStatusCode = 503;
            }
            else if (number == Timeout)
            {
                result.Category = ErrorCategories.SqlTimeout;
                result.Severity = ErrorSeverities.High;
                result.HttpStatusCode = 504;
            }
            else if (ConnectionErrors.Contains(number))
            {
                result.Category = ErrorCategories.DbConnection;
                result.Severity = ErrorSeverities.Critical;
                result.HttpStatusCode = 503;
            }
            else if (ConstraintErrors.Contains(number))
            {
                result.Category = ErrorCategories.SqlConstraint;
                // A constraint violation is nearly always a data or business
                // problem rather than an outage - noisy at critical.
                result.Severity = ErrorSeverities.Medium;
                result.HttpStatusCode = 409;
            }
            else if (procedure != null)
            {
                result.Category = ErrorCategories.SqlProcedure;
                // A RAISERROR/THROW deliberately written into a procedure at
                // severity 11-16 is a business rule the procedure is enforcing,
                // not a system failure.  17+ is a genuine server-side problem.
                var cls = primary?.Class ?? sqlEx.Class;
                result.Severity = cls >= 17 ? ErrorSeverities.Critical : ErrorSeverities.Medium;
                result.HttpStatusCode = cls >= 17 ? 500 : 400;
            }
            else
            {
                result.Category = ErrorCategories.SqlError;
                result.Severity = ErrorSeverities.Critical;
            }
        }

        /// <summary>
        /// Peel wrappers the CLR and the frameworks add, to reach the exception
        /// that carries the real message.  TargetInvocationException and
        /// single-child AggregateException both hide the interesting one.
        /// </summary>
        public static Exception Unwrap(Exception exception, int depth = 0)
        {
            if (exception == null || depth > 8) return exception;

            if (exception is AggregateException agg)
            {
                var flat = agg.Flatten();
                if (flat.InnerExceptions.Count == 1) return Unwrap(flat.InnerExceptions[0], depth + 1);
                return flat;
            }

            if (exception is System.Reflection.TargetInvocationException tie && tie.InnerException != null)
                return Unwrap(tie.InnerException, depth + 1);

            if (exception.GetType().Name == "EntityCommandExecutionException" && exception.InnerException != null)
                return Unwrap(exception.InnerException, depth + 1);

            if (exception.GetType().Name == "DbUpdateException" && exception.InnerException != null)
                return Unwrap(exception.InnerException, depth + 1);

            return exception;
        }

        /// <summary>Find the first exception of type T anywhere in the chain (including aggregates).</summary>
        public static T FindInChain<T>(Exception exception) where T : Exception
        {
            var seen = 0;
            var current = exception;

            while (current != null && seen++ < 16)
            {
                if (current is T match) return match;

                if (current is AggregateException agg)
                {
                    foreach (var inner in agg.Flatten().InnerExceptions)
                    {
                        var found = FindInChain<T>(inner);
                        if (found != null) return found;
                    }
                    return null;
                }

                current = current.InnerException;
            }

            return null;
        }

        /// <summary>Flatten the whole inner-exception chain into one readable block.</summary>
        public static string FlattenInnerChain(Exception exception)
        {
            if (exception?.InnerException == null) return null;

            var sb = new StringBuilder();
            var current = exception.InnerException;
            var depth = 0;

            while (current != null && depth++ < 8)
            {
                if (sb.Length > 0) sb.Append("\n --> ");
                sb.Append(current.GetType().FullName).Append(": ").Append(current.Message);
                current = current.InnerException;
            }

            return sb.ToString();
        }
    }
}
