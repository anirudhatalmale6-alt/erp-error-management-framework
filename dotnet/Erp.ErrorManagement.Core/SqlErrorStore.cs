using System;
using System.Collections.Generic;
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
            int reportedByUserProfileId, string reportedByUserName, CancellationToken ct = default);

        /// <summary>The caller's own tickets. Scoped in SQL, never by a client parameter.</summary>
        Task<List<UserTicketSummary>> ListTicketsForUserAsync(int userProfileId,
            bool onlyOpen, int pageNumber, int pageSize, CancellationToken ct = default);

        /// <summary>
        /// One of the caller's own tickets in end-user form, or null if it does
        /// not exist OR does not belong to them - the two are deliberately
        /// indistinguishable to the caller.
        /// </summary>
        Task<UserTicketDetail> GetTicketForUserAsync(string ticketNumber, int userProfileId,
            CancellationToken ct = default);

        /// <summary>The end user replying on their own ticket. False if not theirs.</summary>
        Task<bool> AddUserCommentAsync(string ticketNumber, int userProfileId, string userName,
            string commentText, CancellationToken ct = default);

        /// <summary>
        /// A ticket raised by hand, with no captured error behind it.
        /// Deliberately not deduplicated - see usp_Ticket_CreateManual.
        /// </summary>
        Task<TicketCreateResult> CreateManualTicketAsync(ManualTicketRequest request,
            CancellationToken ct = default);

        /// <summary>
        /// Assignment as its own audited operation - works without a status
        /// change, validates the target against the roster, and always writes a
        /// history row (including for reassignment).
        /// </summary>
        Task<AssignResult> AssignTicketAsync(string ticketNumber, int? assignToUserProfileId,
            int changedByUserProfileId, string changedByUserName,
            string comments, CancellationToken ct = default);

        Task<List<RequestCategoryOption>> ListRequestCategoriesAsync(CancellationToken ct = default);
    }

    public class ManualTicketRequest
    {
        [JsonProperty("title")]           public string Title { get; set; }
        [JsonProperty("description")]     public string Description { get; set; }
        [JsonProperty("requestCategory")] public string RequestCategory { get; set; }
        [JsonProperty("erpModule")]       public string ErpModule { get; set; }
        [JsonProperty("reportedScreen")]  public string ReportedScreen { get; set; }
        [JsonProperty("severityCode")]    public string SeverityCode { get; set; }

        /// <summary>Set server-side from the token. Never accepted from the client.</summary>
        [JsonIgnore] public int ReportedByUserProfileId { get; set; } = ErpUser.None;
        [JsonIgnore] public string ReportedByUserName { get; set; }
        [JsonIgnore] public string Environment { get; set; }
        [JsonIgnore] public string CreatedVia { get; set; } = "user";
    }

    public class AssignResult
    {
        [JsonProperty("ticketNumber")]   public string TicketNumber { get; set; }
        [JsonProperty("assignedTo")]     public string AssignedToUserName { get; set; }
        [JsonProperty("assignedToName")] public string AssignedToDisplayName { get; set; }
        [JsonProperty("previousAssignedTo")] public string PreviousAssignedToUserName { get; set; }
        [JsonProperty("sequenceNo")]     public int SequenceNo { get; set; }
    }

    public class RequestCategoryOption
    {
        [JsonProperty("code")]                public string Code { get; set; }
        [JsonProperty("displayName")]         public string DisplayName { get; set; }
        [JsonProperty("defaultSeverityCode")] public string DefaultSeverityCode { get; set; }
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
                using (var command = new SqlCommand("ERM.usp_Error_Capture", connection))
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
            int reportedByUserProfileId, string reportedByUserName, CancellationToken ct = default)
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
                        "SELECT ERM_ErrorOccurrenceID FROM ERM.ERM_ErrorOccurrence WHERE ErrorReference = @ref",
                        connection))
                    {
                        lookup.CommandTimeout = _options.CommandTimeoutSeconds;
                        lookup.Parameters.Add("@ref", SqlDbType.VarChar, 24).Value = errorReference;
                        var scalar = await lookup.ExecuteScalarAsync(ct).ConfigureAwait(false);
                        if (scalar == null || scalar == DBNull.Value) return null;
                        occurrenceId = Convert.ToInt64(scalar);
                    }

                    using (var command = new SqlCommand("ERM.usp_Ticket_Create", connection))
                    {
                        command.CommandType = CommandType.StoredProcedure;
                        command.CommandTimeout = _options.CommandTimeoutSeconds;
                        command.Parameters.Add("@OccurrenceId", SqlDbType.BigInt).Value = occurrenceId;
                        command.Parameters.Add("@CreatedVia", SqlDbType.NVarChar, 20).Value = "user";
                        command.Parameters.Add("@UserDescription", SqlDbType.NVarChar, -1).Value =
                            (object)Redactor.ScrubText(userDescription, 4000) ?? DBNull.Value;
                        command.Parameters.Add("@ReportedByUserProfileID", SqlDbType.Int).Value =
                            ErpUser.IsReal(reportedByUserProfileId) ? (object)reportedByUserProfileId : DBNull.Value;
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

        public async Task<List<UserTicketSummary>> ListTicketsForUserAsync(
            int userProfileId, bool onlyOpen, int pageNumber, int pageSize,
            CancellationToken ct = default)
        {
            var result = new List<UserTicketSummary>();
            if (!ErpUser.IsReal(userProfileId)) return result;

            try
            {
                using (var connection = new SqlConnection(_options.ConnectionString))
                using (var command = new SqlCommand("ERM.usp_Ticket_ListForUser", connection))
                {
                    command.CommandType = CommandType.StoredProcedure;
                    command.CommandTimeout = _options.CommandTimeoutSeconds;
                    command.Parameters.Add("@UserProfileID", SqlDbType.Int).Value = userProfileId;
                    command.Parameters.Add("@OnlyOpen", SqlDbType.Bit).Value = onlyOpen;
                    command.Parameters.Add("@PageNumber", SqlDbType.Int).Value = pageNumber;
                    command.Parameters.Add("@PageSize", SqlDbType.Int).Value = pageSize;

                    await connection.OpenAsync(ct).ConfigureAwait(false);
                    using (var reader = await command.ExecuteReaderAsync(ct).ConfigureAwait(false))
                    {
                        while (await reader.ReadAsync(ct).ConfigureAwait(false))
                        {
                            result.Add(new UserTicketSummary
                            {
                                TicketNumber = GetNullableString(reader, "TicketNumber"),
                                Title = GetNullableString(reader, "Title"),
                                StatusCode = GetNullableString(reader, "StatusCode"),
                                StatusName = GetNullableString(reader, "StatusName"),
                                IsOpen = GetBool(reader, "IsOpen"),
                                SeverityName = GetNullableString(reader, "SeverityName"),
                                CreatedUtc = GetNullableDate(reader, "CreatedUtc"),
                                ResolvedUtc = GetNullableDate(reader, "ResolvedUtc"),
                                ClosedUtc = GetNullableDate(reader, "ClosedUtc"),
                                ErpModule = GetNullableString(reader, "ErpModule"),
                                LatestUpdate = GetNullableString(reader, "LatestUpdate"),
                                AwaitingYourReply = GetBool(reader, "AwaitingYourReply")
                            });
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                // A failure to LIST tickets is a read-path failure. It must not
                // throw into the ERP either - an empty list and a logged
                // fallback is the correct degradation for a support panel.
                SafeFallback("Failed to list tickets for user", ex);
            }

            return result;
        }

        public async Task<UserTicketDetail> GetTicketForUserAsync(
            string ticketNumber, int userProfileId, CancellationToken ct = default)
        {
            if (string.IsNullOrWhiteSpace(ticketNumber)) return null;

            try
            {
                using (var connection = new SqlConnection(_options.ConnectionString))
                using (var command = new SqlCommand("ERM.usp_Ticket_GetForUser", connection))
                {
                    command.CommandType = CommandType.StoredProcedure;
                    command.CommandTimeout = _options.CommandTimeoutSeconds;
                    command.Parameters.Add("@TicketNumber", SqlDbType.VarChar, 24).Value = ticketNumber;
                    command.Parameters.Add("@UserProfileID", SqlDbType.Int).Value = userProfileId;

                    await connection.OpenAsync(ct).ConfigureAwait(false);
                    using (var reader = await command.ExecuteReaderAsync(ct).ConfigureAwait(false))
                    {
                        // Result set 1: the header. No row means "not yours, or
                        // not there" - the procedure does the ownership check so
                        // that no caller can ever skip it.
                        if (!await reader.ReadAsync(ct).ConfigureAwait(false)) return null;

                        var detail = new UserTicketDetail
                        {
                            TicketNumber = GetNullableString(reader, "TicketNumber"),
                            Title = GetNullableString(reader, "Title"),
                            StatusCode = GetNullableString(reader, "StatusCode"),
                            StatusName = GetNullableString(reader, "StatusName"),
                            IsOpen = GetBool(reader, "IsOpen"),
                            SeverityName = GetNullableString(reader, "SeverityName"),
                            ErpModule = GetNullableString(reader, "ErpModule"),
                            CreatedUtc = GetNullableDate(reader, "CreatedUtc"),
                            FirstResponseUtc = GetNullableDate(reader, "FirstResponseUtc"),
                            ResolvedUtc = GetNullableDate(reader, "ResolvedUtc"),
                            ClosedUtc = GetNullableDate(reader, "ClosedUtc"),
                            ErrorReference = GetNullableString(reader, "ErrorReference"),
                            YourDescription = GetNullableString(reader, "YourDescription"),
                            ResolutionNotes = GetNullableString(reader, "ResolutionNotes"),
                            AwaitingYourReply = GetBool(reader, "AwaitingYourReply"),
                            CanComment = GetBool(reader, "CanComment"),
                            History = new List<UserTicketHistoryEntry>(),
                            Comments = new List<UserTicketComment>()
                        };

                        // Result set 2: customer-visible status history.
                        if (await reader.NextResultAsync(ct).ConfigureAwait(false))
                        {
                            while (await reader.ReadAsync(ct).ConfigureAwait(false))
                            {
                                detail.History.Add(new UserTicketHistoryEntry
                                {
                                    SequenceNo = (int)(GetNullableLong(reader, "SequenceNo") ?? 0),
                                    StatusName = GetNullableString(reader, "StatusName"),
                                    ChangedUtc = GetNullableDate(reader, "ChangedUtc") ?? default(DateTime),
                                    Comments = GetNullableString(reader, "Comments")
                                });
                            }
                        }

                        // Result set 3: customer-visible comments.
                        if (await reader.NextResultAsync(ct).ConfigureAwait(false))
                        {
                            while (await reader.ReadAsync(ct).ConfigureAwait(false))
                            {
                                detail.Comments.Add(new UserTicketComment
                                {
                                    AuthorRole = GetNullableString(reader, "AuthorRole"),
                                    AuthorName = GetNullableString(reader, "AuthorName"),
                                    CommentText = GetNullableString(reader, "CommentText"),
                                    CreatedUtc = GetNullableDate(reader, "CreatedUtc") ?? default(DateTime)
                                });
                            }
                        }

                        return detail;
                    }
                }
            }
            catch (Exception ex)
            {
                SafeFallback("Failed to read ticket for user", ex);
                return null;
            }
        }

        public async Task<bool> AddUserCommentAsync(
            string ticketNumber, int userProfileId, string userName, string commentText,
            CancellationToken ct = default)
        {
            if (string.IsNullOrWhiteSpace(ticketNumber) || string.IsNullOrWhiteSpace(commentText))
                return false;

            try
            {
                using (var connection = new SqlConnection(_options.ConnectionString))
                using (var command = new SqlCommand("ERM.usp_Ticket_AddUserComment", connection))
                {
                    command.CommandType = CommandType.StoredProcedure;
                    command.CommandTimeout = _options.CommandTimeoutSeconds;
                    command.Parameters.Add("@TicketNumber", SqlDbType.VarChar, 24).Value = ticketNumber;
                    command.Parameters.Add("@UserProfileID", SqlDbType.Int).Value = userProfileId;
                    command.Parameters.Add("@UserName", SqlDbType.NVarChar, 200).Value = (object)userName ?? DBNull.Value;
                    // Scrubbed: the user is typing free text into a field that
                    // support will read and that may be exported. They will
                    // paste a token in here eventually.
                    command.Parameters.Add("@CommentText", SqlDbType.NVarChar, -1).Value =
                        Redactor.ScrubText(commentText, 4000);

                    await connection.OpenAsync(ct).ConfigureAwait(false);
                    var scalar = await command.ExecuteScalarAsync(ct).ConfigureAwait(false);
                    return scalar != null && scalar != DBNull.Value && Convert.ToInt32(scalar) > 0;
                }
            }
            catch (Exception ex)
            {
                SafeFallback("Failed to add user comment", ex);
                return false;
            }
        }

        public async Task<TicketCreateResult> CreateManualTicketAsync(ManualTicketRequest request,
            CancellationToken ct = default)
        {
            if (request == null || string.IsNullOrWhiteSpace(request.Title)) return null;

            try
            {
                using (var connection = new SqlConnection(_options.ConnectionString))
                using (var command = new SqlCommand("ERM.usp_Ticket_CreateManual", connection))
                {
                    command.CommandType = CommandType.StoredProcedure;
                    command.CommandTimeout = _options.CommandTimeoutSeconds;

                    // Scrubbed: free text the user typed, which support will
                    // read and which may be exported. They will paste a token
                    // or a password in here eventually.
                    command.Parameters.Add("@Title", SqlDbType.NVarChar, 400).Value =
                        Redactor.ScrubText(request.Title, 400);
                    command.Parameters.Add("@Description", SqlDbType.NVarChar, -1).Value =
                        (object)Redactor.ScrubText(request.Description, 8000) ?? DBNull.Value;
                    command.Parameters.Add("@RequestCategory", SqlDbType.NVarChar, 60).Value =
                        (object)request.RequestCategory ?? "other";
                    command.Parameters.Add("@ErpModule", SqlDbType.NVarChar, 100).Value =
                        (object)request.ErpModule ?? DBNull.Value;
                    command.Parameters.Add("@ReportedScreen", SqlDbType.NVarChar, 200).Value =
                        (object)request.ReportedScreen ?? DBNull.Value;
                    command.Parameters.Add("@Environment", SqlDbType.NVarChar, 40).Value =
                        (object)(request.Environment ?? _options.Environment) ?? DBNull.Value;
                    command.Parameters.Add("@ReportedByUserProfileID", SqlDbType.Int).Value =
                        ErpUser.IsReal(request.ReportedByUserProfileId)
                            ? (object)request.ReportedByUserProfileId : DBNull.Value;
                    command.Parameters.Add("@ReportedByUserName", SqlDbType.NVarChar, 200).Value =
                        (object)request.ReportedByUserName ?? DBNull.Value;
                    command.Parameters.Add("@CreatedVia", SqlDbType.NVarChar, 20).Value =
                        (object)request.CreatedVia ?? "user";
                    // Severity is a HINT, not a command: the procedure falls
                    // back to the category default. A user marking everything
                    // "critical" must not be able to jump the SLA queue.
                    command.Parameters.Add("@SeverityCode", SqlDbType.NVarChar, 20).Value =
                        (object)request.SeverityCode ?? DBNull.Value;

                    var outParam = command.Parameters.Add("@TicketNumber", SqlDbType.VarChar, 24);
                    outParam.Direction = ParameterDirection.Output;

                    await connection.OpenAsync(ct).ConfigureAwait(false);

                    using (var reader = await command.ExecuteReaderAsync(ct).ConfigureAwait(false))
                    {
                        if (await reader.ReadAsync(ct).ConfigureAwait(false))
                        {
                            return new TicketCreateResult
                            {
                                TicketNumber = GetNullableString(reader, "TicketNumber"),
                                TicketId = GetNullableLong(reader, "TicketId") ?? 0,
                                WasDeduplicated = false
                            };
                        }
                    }

                    var number = outParam.Value as string;
                    return number == null ? null : new TicketCreateResult { TicketNumber = number };
                }
            }
            catch (Exception ex)
            {
                SafeFallback("Manual ticket creation failed", ex);
                return null;
            }
        }

        public async Task<AssignResult> AssignTicketAsync(string ticketNumber, int? assignToUserProfileId,
            int changedByUserProfileId, string changedByUserName,
            string comments, CancellationToken ct = default)
        {
            if (string.IsNullOrWhiteSpace(ticketNumber)) return null;

            try
            {
                using (var connection = new SqlConnection(_options.ConnectionString))
                using (var command = new SqlCommand("ERM.usp_Ticket_Assign", connection))
                {
                    command.CommandType = CommandType.StoredProcedure;
                    command.CommandTimeout = _options.CommandTimeoutSeconds;
                    command.Parameters.Add("@TicketNumber", SqlDbType.VarChar, 24).Value = ticketNumber;
                    // NULL, not -1: null means unassign, and -1 would mean
                    // "assign to the non-user", which the roster forbids.
                    command.Parameters.Add("@AssignToUserProfileID", SqlDbType.Int).Value =
                        assignToUserProfileId.HasValue && ErpUser.IsReal(assignToUserProfileId.Value)
                            ? (object)assignToUserProfileId.Value : DBNull.Value;
                    command.Parameters.Add("@ChangedByUserProfileID", SqlDbType.Int).Value =
                        changedByUserProfileId;
                    command.Parameters.Add("@ChangedByUserName", SqlDbType.NVarChar, 200).Value =
                        (object)changedByUserName ?? DBNull.Value;
                    command.Parameters.Add("@Comments", SqlDbType.NVarChar, -1).Value =
                        (object)Redactor.ScrubText(comments, 2000) ?? DBNull.Value;

                    await connection.OpenAsync(ct).ConfigureAwait(false);
                    using (var reader = await command.ExecuteReaderAsync(ct).ConfigureAwait(false))
                    {
                        if (!await reader.ReadAsync(ct).ConfigureAwait(false)) return null;

                        return new AssignResult
                        {
                            TicketNumber = GetNullableString(reader, "TicketNumber"),
                            AssignedToUserName = GetNullableString(reader, "AssignedToUserName"),
                            AssignedToDisplayName = GetNullableString(reader, "AssignedToDisplayName"),
                            PreviousAssignedToUserName = GetNullableString(reader, "PreviousAssignedToUserName"),
                            SequenceNo = (int)(GetNullableLong(reader, "SequenceNo") ?? 0)
                        };
                    }
                }
            }
            catch (Exception ex)
            {
                // Assignment errors are RAISERROR from the procedure - an
                // unauthorised caller, or a target who is not on the roster.
                // Surfaced as null so the API can return a clean 400 rather
                // than leaking the SQL message.
                SafeFallback("Ticket assignment failed", ex);
                return null;
            }
        }

        public async Task<List<RequestCategoryOption>> ListRequestCategoriesAsync(CancellationToken ct = default)
        {
            var result = new List<RequestCategoryOption>();

            try
            {
                using (var connection = new SqlConnection(_options.ConnectionString))
                using (var command = new SqlCommand("ERM.usp_RequestCategory_List", connection))
                {
                    command.CommandType = CommandType.StoredProcedure;
                    command.CommandTimeout = _options.CommandTimeoutSeconds;

                    await connection.OpenAsync(ct).ConfigureAwait(false);
                    using (var reader = await command.ExecuteReaderAsync(ct).ConfigureAwait(false))
                    {
                        while (await reader.ReadAsync(ct).ConfigureAwait(false))
                        {
                            result.Add(new RequestCategoryOption
                            {
                                Code = GetNullableString(reader, "Code"),
                                DisplayName = GetNullableString(reader, "DisplayName"),
                                DefaultSeverityCode = GetNullableString(reader, "DefaultSeverityCode")
                            });
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                SafeFallback("Failed to list request categories", ex);
            }

            return result;
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

        private static DateTime? GetNullableDate(IDataRecord r, string name)
        {
            var i = r.GetOrdinal(name);
            return r.IsDBNull(i) ? (DateTime?)null : Convert.ToDateTime(r.GetValue(i));
        }

        private static bool GetBool(IDataRecord r, string name)
        {
            var i = r.GetOrdinal(name);
            return !r.IsDBNull(i) && Convert.ToBoolean(r.GetValue(i));
        }
    }
}
