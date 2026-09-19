namespace Erp.ErrorManagement
{
    /// <summary>
    /// The ERP user identity used throughout the framework.
    ///
    /// There is exactly one: ATC's <c>UserProfileID</c>. The framework does not
    /// mint an identifier of its own and does not map between one and the ERP's
    /// - it takes the value the ERP already sends on the request (as
    /// <c>CreatedBy</c>, <c>UpdatedBy</c> or <c>UserProfileID</c>) and the value
    /// <c>generic_service.GetUserProfileKey()</c> returns in Angular.
    ///
    /// An earlier version of this framework carried a text user id lifted from
    /// the JWT. That was a second identity for the same person, which is a
    /// second thing to keep in step - and it would have been wrong precisely
    /// when it mattered, which is when somebody is trying to work out who hit a
    /// fault.
    /// </summary>
    public static class ErpUser
    {
        /// <summary>
        /// ATC's standard non-user value. Used when no ERP UserProfileID exists:
        /// an error captured from a public page, a row written by a scheduled
        /// job, a ticket raised by an automatic rule.
        ///
        /// It is NOT a user. Nothing may be owned by it, and it can never hold
        /// support rights - the roster has a CHECK constraint forbidding it, and
        /// both SQL predicates refuse anything &lt;= 0. Otherwise every
        /// unauthenticated caller would share one identity, and that identity
        /// would own every ticket raised from a public page.
        /// </summary>
        public const int None = -1;

        /// <summary>
        /// True when the value identifies a real ERP user, rather than being
        /// absent, the non-user value, or a nonsense id.
        /// </summary>
        public static bool IsReal(int userProfileId) => userProfileId > 0;

        /// <summary>
        /// Normalises anything the request produced into a value safe to store:
        /// null, zero and negatives all collapse to <see cref="None"/>.
        /// </summary>
        public static int Normalize(int? userProfileId) =>
            userProfileId.HasValue && userProfileId.Value > 0 ? userProfileId.Value : None;
    }
}
