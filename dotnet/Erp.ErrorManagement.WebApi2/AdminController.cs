using System;
using System.Collections.Generic;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Http;

namespace Erp.ErrorManagement.WebApi2
{
    /// <summary>
    /// The support console API.
    ///
    /// EVERY action carries a [RequiresSupport] capability. There is no action
    /// on this controller that an ordinary ERP user can call, and the check is
    /// per action rather than per controller because the capabilities genuinely
    /// differ: a read-only manager may list errors but must not change ticket
    /// state, and viewing a stack trace is a separate permission from viewing
    /// the list, because a stack trace is where the sensitive detail lives.
    ///
    /// Enforcement is in ErpAdminAuthorizationFilter, registered once by
    /// UseErpErrorManagement. The Angular route guard is cosmetic by comparison:
    /// it stops people seeing a menu item they cannot use. It is not the
    /// security boundary, and anyone with a browser console can bypass it.
    /// </summary>
    [RoutePrefix("api/error-management/admin")]
    [RequiresSupport(SupportCapability.ViewErrors)]   // controller-wide floor
    public class AdminController : ApiController
    {
        private readonly IErrorStore _store;
        private readonly ISupportDirectory _directory;

        public AdminController(IErrorStore store, ISupportDirectory directory)
        {
            _store = store ?? throw new ArgumentNullException(nameof(store));
            _directory = directory ?? throw new ArgumentNullException(nameof(directory));
        }

        /// <summary>
        /// The resolved identity for this request, put there by the filter so
        /// the action never has to resolve it again.
        /// </summary>
        private SupportIdentity Support =>
            Request.Properties.TryGetValue(ErpAdminAuthorizationFilter.IdentityKey, out var v)
                ? (SupportIdentity)v
                : SupportIdentity.Anonymous;

        /// <summary>
        /// What the console should show this user. The UI calls this first and
        /// hides what the capabilities do not permit - but every endpoint
        /// re-checks, so a tampered response only changes what is drawn.
        /// </summary>
        [HttpGet, Route("whoami")]
        public IHttpActionResult WhoAmI()
        {
            return Ok(Support);
        }

        /// <summary>The "assign to" picker.</summary>
        [HttpGet, Route("assignable-users")]
        [RequiresSupport(SupportCapability.ManageTickets)]
        public async Task<IHttpActionResult> AssignableUsers(
            short? queueId = null, bool includeUnavailable = false,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var users = await _directory
                .ListAssignableAsync(queueId, includeUnavailable, cancellationToken)
                .ConfigureAwait(false);

            return Ok(new { items = users, total = users.Count });
        }

        public class AssignRequest
        {
            /// <summary>
            /// The assignee's ERP UserProfileID. Null means unassign.
            /// The assignee's NAME is not accepted and not needed - it is
            /// resolved from the roster inside the procedure, so the stored name
            /// cannot disagree with the stored id.
            /// </summary>
            public int? AssignToUserProfileId { get; set; }
            public string Comments { get; set; }
        }

        /// <summary>
        /// Assign or reassign. Recorded in the ticket's audit history every
        /// time, including reassignment between two support users - which is
        /// not a status change and therefore used to leave no trace at all.
        ///
        /// The assignee is validated against the roster in SQL, so a typo or a
        /// departed colleague is rejected rather than silently parking the
        /// ticket with nobody.
        /// </summary>
        [HttpPost, Route("tickets/{ticketNumber}/assign")]
        [RequiresSupport(SupportCapability.ManageTickets)]
        public async Task<IHttpActionResult> Assign(
            string ticketNumber, [FromBody] AssignRequest request,
            CancellationToken cancellationToken)
        {
            if (request == null) return BadRequest("A body is required.");

            var me = Support;

            var result = await _store.AssignTicketAsync(
                ticketNumber,
                request.AssignToUserProfileId,
                // WHO performed it comes from the resolved identity, never from
                // the body. Accepting it from the caller would make the audit
                // trail worth nothing.
                me.UserProfileId,
                me.UserName,
                request.Comments,
                cancellationToken).ConfigureAwait(false);

            if (result == null)
            {
                // The procedure refuses an assignee who is not active and
                // assignable. Deliberately a 400 with a generic message rather
                // than echoing the SQL error.
                return Content(HttpStatusCode.BadRequest, new
                {
                    message = "The ticket could not be assigned. Check that the ticket exists and "
                            + "that the assignee is an active member of the support roster."
                });
            }

            return Ok(result);
        }

        /// <summary>
        /// Raise a ticket on a user's behalf - a phone call, a corridor
        /// conversation. The ticket is owned by the USER, so it appears in
        /// their My Tickets rather than the agent's.
        /// </summary>
        public class OnBehalfRequest
        {
            public string Title { get; set; }
            public string Description { get; set; }
            public string RequestCategory { get; set; }
            public string ErpModule { get; set; }
            public string ReportedScreen { get; set; }
            public string SeverityCode { get; set; }
            /// <summary>The ERP UserProfileID of the user this ticket belongs to.</summary>
            public int? OnBehalfOfUserProfileId { get; set; }
            public string OnBehalfOfUserName { get; set; }
        }

        [HttpPost, Route("tickets/on-behalf")]
        [RequiresSupport(SupportCapability.ManageTickets)]
        public async Task<IHttpActionResult> CreateOnBehalf(
            [FromBody] OnBehalfRequest request, CancellationToken cancellationToken)
        {
            if (request == null || string.IsNullOrWhiteSpace(request.Title))
                return BadRequest("A title is required.");

            if (!request.OnBehalfOfUserProfileId.HasValue
                || !ErpUser.IsReal(request.OnBehalfOfUserProfileId.Value))
                return BadRequest("The UserProfileID this ticket is for must be supplied.");

            var result = await _store.CreateManualTicketAsync(new ManualTicketRequest
            {
                Title = request.Title,
                Description = request.Description,
                RequestCategory = request.RequestCategory,
                ErpModule = request.ErpModule,
                ReportedScreen = request.ReportedScreen,
                SeverityCode = request.SeverityCode,
                ReportedByUserProfileId = request.OnBehalfOfUserProfileId.Value,
                ReportedByUserName = request.OnBehalfOfUserName,
                CreatedVia = "admin"
            }, cancellationToken).ConfigureAwait(false);

            if (result == null)
                return Content(HttpStatusCode.ServiceUnavailable,
                    new { message = "The ticket could not be created." });

            return Ok(result);
        }
    }
}
