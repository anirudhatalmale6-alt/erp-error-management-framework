using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;

namespace Erp.ErrorManagement
{
    /// <summary>
    /// What the current caller is allowed to do in the support console.
    ///
    /// Capability flags rather than a role hierarchy. A hierarchy forces you to
    /// decide whether "can triage" outranks "can configure", and that question
    /// has no correct answer - real support teams have people who do one and
    /// not the other.
    /// </summary>
    public class SupportIdentity
    {
        [JsonProperty("isSupportUser")]      public bool IsSupportUser { get; set; }
        [JsonProperty("displayName")]        public string DisplayName { get; set; }
        [JsonProperty("userId")]             public string UserId { get; set; }
        [JsonProperty("userName")]           public string UserName { get; set; }
        [JsonProperty("roleCode")]           public string RoleCode { get; set; }
        [JsonProperty("roleName")]           public string RoleName { get; set; }

        [JsonProperty("canViewErrors")]      public bool CanViewErrors { get; set; }
        [JsonProperty("canViewDiagnostics")] public bool CanViewDiagnostics { get; set; }
        [JsonProperty("canManageTickets")]   public bool CanManageTickets { get; set; }
        [JsonProperty("canBeAssigned")]      public bool CanBeAssigned { get; set; }
        [JsonProperty("canTriage")]          public bool CanTriage { get; set; }
        [JsonProperty("canConfigure")]       public bool CanConfigure { get; set; }

        [JsonProperty("defaultQueueCode")]   public string DefaultQueueCode { get; set; }

        /// <summary>Nobody. The default, and what an unrecognised caller gets.</summary>
        public static SupportIdentity Anonymous => new SupportIdentity { IsSupportUser = false };

        public bool Has(SupportCapability capability)
        {
            if (!IsSupportUser) return false;

            switch (capability)
            {
                case SupportCapability.ViewErrors:      return CanViewErrors;
                case SupportCapability.ViewDiagnostics: return CanViewDiagnostics;
                case SupportCapability.ManageTickets:   return CanManageTickets;
                case SupportCapability.Triage:          return CanTriage;
                case SupportCapability.Configure:       return CanConfigure;
                default:                                return false;
            }
        }
    }

    public enum SupportCapability
    {
        ViewErrors,
        ViewDiagnostics,
        ManageTickets,
        Triage,
        Configure
    }

    public interface ISupportDirectory
    {
        /// <summary>
        /// Resolve the caller against the support roster. Returns
        /// SupportIdentity.Anonymous when they are not support staff - the
        /// absence of a roster row IS the answer, not an error.
        /// </summary>
        Task<SupportIdentity> ResolveAsync(string userId, string userName, CancellationToken ct = default);

        Task<List<AssignableUser>> ListAssignableAsync(short? queueId, bool includeUnavailable,
            CancellationToken ct = default);
    }

    public class AssignableUser
    {
        [JsonProperty("userId")]          public string UserId { get; set; }
        [JsonProperty("userName")]        public string UserName { get; set; }
        [JsonProperty("displayName")]     public string DisplayName { get; set; }
        [JsonProperty("roleCode")]        public string RoleCode { get; set; }
        [JsonProperty("roleName")]        public string RoleName { get; set; }
        [JsonProperty("defaultQueueCode")] public string DefaultQueueCode { get; set; }
        [JsonProperty("isAvailable")]     public bool IsAvailable { get; set; }
        /// <summary>Current open workload, so a lead can see who is already buried.</summary>
        [JsonProperty("openTicketCount")] public long OpenTicketCount { get; set; }
    }

    /// <summary>
    /// Resolves support identity from the erp_err roster.
    ///
    /// DESIGN NOTE - why the roster and not just the JWT role claim.
    ///
    /// Reading a role straight off the token is tempting and is what most
    /// integrations do. Two reasons this reads the database instead:
    ///
    ///  1. TOKEN LIFETIME. Revoking someone's support access has to take effect
    ///     now, not whenever their token happens to expire. A token issued this
    ///     morning still carries this morning's roles.
    ///  2. WHO OWNS THE LIST. Support membership is operational data that the
    ///     support lead should be able to change. Putting it in the identity
    ///     provider makes every change a request to whoever administers auth.
    ///
    /// The token is still required - authentication comes from it, and an
    /// unauthenticated request never reaches here. The roster decides
    /// AUTHORISATION. If you would rather drive authorisation from a token
    /// claim, set ErrorCaptureOptions.SupportRoleClaims and the API will accept
    /// either source; see ErpAdminAuthorization.
    /// </summary>
    public class SqlSupportDirectory : ISupportDirectory
    {
        private readonly ErrorCaptureOptions _options;

        public SqlSupportDirectory(ErrorCaptureOptions options)
        {
            _options = options ?? throw new ArgumentNullException(nameof(options));
            _options.Validate();
        }

        public async Task<SupportIdentity> ResolveAsync(string userId, string userName,
            CancellationToken ct = default)
        {
            if (userId == null && userName == null) return SupportIdentity.Anonymous;

            try
            {
                using (var connection = new SqlConnection(_options.ConnectionString))
                using (var command = new SqlCommand("erp_err.usp_Support_WhoAmI", connection))
                {
                    command.CommandType = CommandType.StoredProcedure;
                    command.CommandTimeout = _options.CommandTimeoutSeconds;
                    command.Parameters.Add("@UserId", SqlDbType.NVarChar, 128).Value = (object)userId ?? DBNull.Value;
                    command.Parameters.Add("@UserName", SqlDbType.NVarChar, 200).Value = (object)userName ?? DBNull.Value;

                    await connection.OpenAsync(ct).ConfigureAwait(false);
                    using (var reader = await command.ExecuteReaderAsync(ct).ConfigureAwait(false))
                    {
                        if (!await reader.ReadAsync(ct).ConfigureAwait(false))
                            return SupportIdentity.Anonymous;

                        return new SupportIdentity
                        {
                            IsSupportUser = true,
                            DisplayName = Str(reader, "DisplayName"),
                            UserId = Str(reader, "UserId"),
                            UserName = Str(reader, "UserName"),
                            RoleCode = Str(reader, "RoleCode"),
                            RoleName = Str(reader, "RoleName"),
                            CanViewErrors = Bit(reader, "CanViewErrors"),
                            CanViewDiagnostics = Bit(reader, "CanViewDiagnostics"),
                            CanManageTickets = Bit(reader, "CanManageTickets"),
                            CanBeAssigned = Bit(reader, "CanBeAssigned"),
                            CanTriage = Bit(reader, "CanTriage"),
                            CanConfigure = Bit(reader, "CanConfigure"),
                            DefaultQueueCode = Str(reader, "DefaultQueueCode")
                        };
                    }
                }
            }
            catch (Exception ex)
            {
                // FAIL CLOSED.
                //
                // Every other failure path in this framework degrades to
                // "carry on without capturing", because losing an error record
                // is better than breaking the ERP. This one is the exception:
                // if we cannot determine authorisation, the answer is NO. An
                // authorisation check that fails open during a database blip is
                // not a check.
                try
                {
                    _options.FallbackLogger?.Invoke("Support identity resolution failed - denying access", ex);
                }
                catch
                {
                    /* nowhere left to report to */
                }

                return SupportIdentity.Anonymous;
            }
        }

        public async Task<List<AssignableUser>> ListAssignableAsync(short? queueId, bool includeUnavailable,
            CancellationToken ct = default)
        {
            var result = new List<AssignableUser>();

            try
            {
                using (var connection = new SqlConnection(_options.ConnectionString))
                using (var command = new SqlCommand("erp_err.usp_SupportUser_ListAssignable", connection))
                {
                    command.CommandType = CommandType.StoredProcedure;
                    command.CommandTimeout = _options.CommandTimeoutSeconds;
                    command.Parameters.Add("@QueueId", SqlDbType.SmallInt).Value =
                        queueId.HasValue ? (object)queueId.Value : DBNull.Value;
                    command.Parameters.Add("@IncludeUnavailable", SqlDbType.Bit).Value = includeUnavailable;

                    await connection.OpenAsync(ct).ConfigureAwait(false);
                    using (var reader = await command.ExecuteReaderAsync(ct).ConfigureAwait(false))
                    {
                        while (await reader.ReadAsync(ct).ConfigureAwait(false))
                        {
                            result.Add(new AssignableUser
                            {
                                UserId = Str(reader, "UserId"),
                                UserName = Str(reader, "UserName"),
                                DisplayName = Str(reader, "DisplayName"),
                                RoleCode = Str(reader, "RoleCode"),
                                RoleName = Str(reader, "RoleName"),
                                DefaultQueueCode = Str(reader, "DefaultQueueCode"),
                                IsAvailable = Bit(reader, "IsAvailable"),
                                OpenTicketCount = Convert.ToInt64(reader["OpenTicketCount"] is DBNull
                                    ? 0 : reader["OpenTicketCount"])
                            });
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                try
                {
                    _options.FallbackLogger?.Invoke("Failed to list assignable support users", ex);
                }
                catch
                {
                    /* nowhere left to report to */
                }
            }

            return result;
        }

        private static string Str(IDataRecord r, string name)
        {
            var i = r.GetOrdinal(name);
            return r.IsDBNull(i) ? null : Convert.ToString(r.GetValue(i));
        }

        private static bool Bit(IDataRecord r, string name)
        {
            var i = r.GetOrdinal(name);
            return !r.IsDBNull(i) && Convert.ToBoolean(r.GetValue(i));
        }
    }
}
