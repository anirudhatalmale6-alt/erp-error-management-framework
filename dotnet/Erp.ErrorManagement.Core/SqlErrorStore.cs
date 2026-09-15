using System;
using System.Data;
using System.Data.SqlClient;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;

namespace Erp.ErrorManagement
{
    public interface IErrorStore
    {
        Task<ErrorCaptureResult> CaptureAsync(ErrorEnvelope envelope, string source, CancellationToken ct = default);
        Task<TicketCreateResult> CreateTicketAsync(string errorReference, string userDescription,
            string reportedByUserId, string reportedByUserName, CancellationToken ct = default);
    }

    /// <summary>
    /// ADO.NET persistence.  Deliberately NOT Entity Framework.
    ///
    /// Reasoning, since the brief asks the freelancer to recommend Code First vs
    /// Database First:
    ///
    ///  - The framework has to run inside a .NET Framework 4.7.2 application
    ///    (EF6) AND a .NET 8 application (EF Core).  Those are different ORMs
    ///    with different migration systems.  Sharing one netstandard2.0
    ///    assembly between them rules out taking a dependency on either.
    ///  - The capture path is the code that runs when the application is
    ///    ALREADY in trouble.  A DbContext carries change tracking, model
    ///    building, connection resiliency and a first-call warm-up cost; a
    ///    SqlCommand carries none of that.  When you are logging a deadlock you
    ///    do not want your logger to take a dependency on the same ORM that just
    ///    produced it.
    ///  - The framework's own schema is versioned by ordered SQL scripts
    ///    (db/001..006) and a SchemaVersion ledger, which is Database First in
    ///    the only sense that matters: the scripts are the source of truth and a
    ///    DBA can read, review and run them before they touch production. On a
    ///    live ERP that review step is not optional.
    ///
    /// Consuming applications that want a typed read model over the error data
    /// are free to scaffold EF Core entities from the same schema - the tables
    /// are plain and the procedures return flat result sets.
    /// </summary>
    public class SqlErrorStore : IErrorStore
    {
        private readonly ErrorCaptureOptions _options;

        public SqlErrorStore(ErrorCaptureOptions options)
        {
            _options = options ?? throw new ArgumentNullException(nameof(options));
            _options.Validate();
        }

        public async Task<ErrorCaptureResult> CaptureAsync(ErrorEnvelope envelope, string source,
            CancellationToken ct = default)
        {
            if (envelope == null) return null;

            try
            {
                var json = JsonConvert.SerializeObject(envelope, new JsonSerializerSettings
                {
                    NullValueHandling = NullValueHandling.Ignore,
                    DateFormatHandling = DateFormatHandling.IsoDateFormat
                });

                using (var connection = new SqlConnection(_options.ConnectionString))
                using (var command = new SqlCommand("erp_err.usp_Error_Capture", connection))
                {
                    command.CommandType = CommandType.StoredProcedure;
                    command.CommandTimeout = _options.CommandTimeoutSeconds;
                    command.Parameters.Add("@EnvelopeJson", SqlDbType.NVarChar, -1).Value = json;
                    command.Parameters.Add("@Source", SqlDbType.NVarChar, 60).Value =
                        (object)source ?? DBNull.Value;

                    await connection.OpenAsync(ct).ConfigureAwait(false);

                    using (var reader = await command.ExecuteReaderAsync(ct).ConfigureAwait(false))
                    {
                        if (!await reader.ReadAsync(ct).ConfigureAwait(false)) return null;

                        return new ErrorCaptureResult
                        {
                            ErrorReference = GetNullableString(reader, "ErrorReference"),
                            OccurrenceId = GetNullableLong(reader, "OccurrenceId"),
                            FingerprintId = GetNullableLong(reader, "FingerprintId"),
                            ShouldNotifyUser = GetBool(reader, "ShouldNotifyUser"),
                            AutoTicketNumber = GetNullableString(reader, "AutoTicketNumber"),
                            IsKnownIssue = GetBool(reader, "IsKnownIssue")
                        };
                    }
                }
            }
            catch (Exception ex)
            {
                // THE most important catch in the framework.
                //
                // If the error store is down, unreachable, or its schema has
                // drifted, the ERP request that triggered this must still
                // complete exactly as it would have.  Capture is best-effort by
                // design; it is never allowed to become the reason a user
                // cannot post a journal.
                SafeFallback("Error capture failed", ex);
                return null;
            }
        }

        public async Task<TicketCreateResult> CreateTicketAsync(string errorReference, string userDescription,
            string reportedByUserId, string reportedByUserName, CancellationToken ct = default)
        {
            if (string.IsNullOrWhiteSpace(errorReference)) return null;

            try
            {
                using (var connection = new SqlConnection(_options.ConnectionString))
                {
                    await connection.OpenAsync(ct).ConfigureAwait(false);

                    // Resolve the reference to an occurrence id first: the
                    // ticket procedure takes the id, and the reference is what
                    // the user has in front of them.
                    long occurrenceId;
                    using (var lookup = new SqlCommand(
                        "SELECT OccurrenceId FROM erp_err.ErrorOccurrence WHERE ErrorReference = @ref",
                        connection))
                    {
                        lookup.CommandTimeout = _options.CommandTimeoutSeconds;
                        lookup.Parameters.Add("@ref", SqlDbType.VarChar, 24).Value = errorReference;
                        var scalar = await lookup.ExecuteScalarAsync(ct).ConfigureAwait(false);
                        if (scalar == null || scalar == DBNull.Value) return null;
                        occurrenceId = Convert.ToInt64(scalar);
                    }

                    using (var command = new SqlCommand("erp_err.usp_Ticket_Create", connection))
                    {
                        command.CommandType = CommandType.StoredProcedure;
                        command.CommandTimeout = _options.CommandTimeoutSeconds;
                        command.Parameters.Add("@OccurrenceId", SqlDbType.BigInt).Value = occurrenceId;
                        command.Parameters.Add("@CreatedVia", SqlDbType.NVarChar, 20).Value = "user";
                        command.Parameters.Add("@UserDescription", SqlDbType.NVarChar, -1).Value =
                            (object)Redactor.ScrubText(userDescription, 4000) ?? DBNull.Value;
                        command.Parameters.Add("@ReportedByUserId", SqlDbType.NVarChar, 128).Value =
                            (object)reportedByUserId ?? DBNull.Value;
                        command.Parameters.Add("@ReportedByUserName", SqlDbType.NVarChar, 200).Value =
                            (object)reportedByUserName ?? DBNull.Value;
                        command.Parameters.Add("@QueueId", SqlDbType.SmallInt).Value = DBNull.Value;

                        var outParam = command.Parameters.Add("@TicketNumber", SqlDbType.VarChar, 24);
                        outParam.Direction = ParameterDirection.Output;

                        using (var reader = await command.ExecuteReaderAsync(ct).ConfigureAwait(false))
                        {
                            if (await reader.ReadAsync(ct).ConfigureAwait(false))
                            {
                                return new TicketCreateResult
                                {
                                    TicketNumber = GetNullableString(reader, "TicketNumber"),
                                    TicketId = GetNullableLong(reader, "TicketId") ?? 0,
                                    WasDeduplicated = GetBool(reader, "WasDeduplicated")
                                };
                            }
                        }

                        // Output parameters are only populated once every result
                        // set has been consumed - reading it before the reader
                        // is closed silently yields null.
                        var number = outParam.Value as string;
                        return number == null ? null : new TicketCreateResult { TicketNumber = number };
                    }
                }
            }
            catch (Exception ex)
            {
                SafeFallback("Ticket creation failed", ex);
                return null;
            }
        }

        private void SafeFallback(string message, Exception ex)
        {
            try
            {
                _options.FallbackLogger?.Invoke(message, ex);
            }
            catch
            {
                // The fallback logger failing is the end of the line.  There is
                // nowhere left to report to, and throwing here would defeat the
                // entire purpose of the outer catch.
            }
        }

        private static string GetNullableString(IDataRecord r, string name)
        {
            var i = r.GetOrdinal(name);
            return r.IsDBNull(i) ? null : r.GetString(i);
        }

        private static long? GetNullableLong(IDataRecord r, string name)
        {
            var i = r.GetOrdinal(name);
            return r.IsDBNull(i) ? (long?)null : Convert.ToInt64(r.GetValue(i));
        }

        private static bool GetBool(IDataRecord r, string name)
        {
            var i = r.GetOrdinal(name);
            return !r.IsDBNull(i) && Convert.ToBoolean(r.GetValue(i));
        }
    }
}
