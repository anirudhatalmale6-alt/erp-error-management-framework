using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Web;
using System.Web.Http;

namespace Erp.ErrorManagement.WebApi2
{
    /// <summary>
    /// The endpoints the Angular library talks to.
    ///
    /// Authentication model, which is worth stating precisely because the ERP
    /// has both protected and public pages:
    ///
    ///   POST errors          [AllowAnonymous] - capture must work on a public
    ///                        page, where the browser has no token. Identity is
    ///                        read from the JWT WHEN PRESENT and left empty
    ///                        otherwise. Rate-limited per IP when anonymous.
    ///   POST errors/beacon   [AllowAnonymous] - fired during page unload; there
    ///                        is no opportunity to negotiate auth.
    ///   POST tickets         Authenticated by default. A ticket has an owner,
    ///                        lands in a support queue and notifies people;
    ///                        an open endpoint for that is a spam channel.
    ///                        Opt in with AllowAnonymousTicketCreation.
    ///   GET  tickets/mine    Authenticated, always. Scoped to the caller.
    ///   GET  tickets/{n}     Authenticated, and ownership is enforced.
    ///
    /// [AllowAnonymous] only has an effect where a global authorize filter is in
    /// place. If the ERP protects routes with Web API's global filter or with an
    /// OWIN stage, these attributes are what exempt capture from it. If it
    /// protects routes some other way (a custom module, IIS-level rules), that
    /// mechanism has to exempt these two routes as well - see docs/ARCHITECTURE
    /// §4.5. That is a one-line allow entry, but it does have to be done, and it
    /// is the one part of the integration I cannot do from inside the package.
    /// </summary>
    [RoutePrefix("api/error-management")]
    public class ErrorManagementController : ApiController
    {
        private readonly ErrorCaptureService _capture;
        private readonly IErrorStore _store;
        private readonly ErrorCaptureOptions _options;
        private readonly AnonymousCaptureThrottle _throttle;

        public ErrorManagementController(
            ErrorCaptureService capture,
            IErrorStore store,
            AnonymousCaptureThrottle throttle)
        {
            _capture = capture ?? throw new ArgumentNullException(nameof(capture));
            _store = store ?? throw new ArgumentNullException(nameof(store));
            _throttle = throttle ?? throw new ArgumentNullException(nameof(throttle));
            _options = capture.Options;
        }

        /* ==================================================== capture ==== */

        /// <summary>
        /// Batched capture from the browser.  Returns one result per envelope,
        /// IN THE SAME ORDER, because the client matches them positionally.
        /// </summary>
        [HttpPost, Route("errors")]
        [AllowAnonymous]
        public async Task<IHttpActionResult> CaptureErrors(
            [FromBody] List<ErrorEnvelope> envelopes, CancellationToken cancellationToken)
        {
            if (envelopes == null || envelopes.Count == 0) return Ok(new List<ErrorCaptureResult>());

            var isAuthenticated = IsAuthenticated();

            if (!isAuthenticated && !_options.AllowAnonymousCapture)
            {
                // Refuse, but do not 401: a 401 would send the browser's auth
                // interceptor into a token refresh or a redirect because an
                // ERROR REPORT was rejected. 204 says "heard you, discarded it"
                // and keeps the failure inside the framework.
                return StatusCode(HttpStatusCode.NoContent);
            }

            // Bound the batch: this endpoint is reachable by anything that can
            // reach the ERP, and an unbounded list is a free denial of service
            // against the error store.
            if (envelopes.Count > 50) envelopes = envelopes.Take(50).ToList();

            if (!isAuthenticated)
            {
                var allowed = _throttle.TryAcquire(ThrottleKey(), envelopes.Count);
                if (allowed <= 0)
                {
                    // Every result slot still has to be filled or the client
                    // would match reference numbers to the wrong envelopes.
                    return Ok(envelopes.Select(_ => new ErrorCaptureResult
                    {
                        ShouldNotifyUser = true,
                        CanCreateTicket = false
                    }).ToList());
                }
                if (allowed < envelopes.Count) envelopes = envelopes.Take(allowed).ToList();
            }

            var clientIp = GetClientIp();
            var canCreateTicket = isAuthenticated || _options.AllowAnonymousTicketCreation;
            var results = new List<ErrorCaptureResult>(envelopes.Count);

            foreach (var envelope in envelopes)
            {
                var result = await _capture
                    .CaptureClientEnvelopeAsync(envelope, clientIp, cancellationToken)
                    .ConfigureAwait(false);

                // A null result still occupies its slot, or every subsequent
                // envelope in the batch would be matched to the wrong reference.
                result = result ?? new ErrorCaptureResult { ShouldNotifyUser = true };

                // Tells the dialog whether to offer "Report issue" at all.
                // Offering a button that will 401 is worse than not offering it.
                result.CanCreateTicket = canCreateTicket && result.ErrorReference != null;
                results.Add(result);
            }

            return Ok(results);
        }

        /// <summary>
        /// navigator.sendBeacon target.  Fired during page unload, so it must
        /// answer immediately and can never require auth negotiation or a
        /// redirect - the browser is already tearing the page down.
        /// </summary>
        [HttpPost, Route("errors/beacon")]
        [AllowAnonymous]
        public async Task<IHttpActionResult> CaptureBeacon(
            [FromBody] List<ErrorEnvelope> envelopes, CancellationToken cancellationToken)
        {
            if (envelopes != null && (IsAuthenticated() || _options.AllowAnonymousCapture))
            {
                var batch = envelopes.Take(50).ToList();

                if (!IsAuthenticated())
                {
                    var allowed = _throttle.TryAcquire(ThrottleKey(), batch.Count);
                    batch = batch.Take(Math.Max(0, allowed)).ToList();
                }

                var clientIp = GetClientIp();
                foreach (var envelope in batch)
                {
                    await _capture.CaptureClientEnvelopeAsync(envelope, clientIp, cancellationToken)
                        .ConfigureAwait(false);
                }
            }

            // 204: sendBeacon ignores the body, and returning one wastes bytes
            // on a connection the browser is about to drop.
            return StatusCode(HttpStatusCode.NoContent);
        }

        /* ==================================================== tickets ==== */

        public class CreateTicketRequest
        {
            public string ErrorReference { get; set; }
            public string UserDescription { get; set; }
        }

        [HttpPost, Route("tickets")]
        [AllowAnonymous]   // the check below is explicit, so the policy is visible here
        public async Task<IHttpActionResult> CreateTicket(
            [FromBody] CreateTicketRequest request, CancellationToken cancellationToken)
        {
            if (request == null || string.IsNullOrWhiteSpace(request.ErrorReference))
                return BadRequest("errorReference is required.");

            if (!IsAuthenticated() && !_options.AllowAnonymousTicketCreation)
            {
                return Content(HttpStatusCode.Forbidden, new
                {
                    message = "Your issue has been recorded. Please quote the reference below " +
                              "when you contact support.",
                    errorReference = request.ErrorReference,
                    canCreateTicket = false
                });
            }

            if (!IsAuthenticated())
            {
                // Anonymous ticket creation is opt-in, and when it is on it is
                // still throttled - it is the more expensive of the two writes.
                if (_throttle.TryAcquire(ThrottleKey(), 1) <= 0)
                    return Content((HttpStatusCode)429, new
                    {
                        message = "Too many reports from this location. Your error was still recorded."
                    });
            }

            var ctx = ErrorContext.Values;

            var result = await _store.CreateTicketAsync(
                request.ErrorReference,
                request.UserDescription,
                UserProfileId(ctx),
                ctx?.UserName,
                cancellationToken).ConfigureAwait(false);

            if (result == null)
                return Content(HttpStatusCode.ServiceUnavailable,
                    new { message = "The ticket could not be created. Your error has still been recorded." });

            return Ok(result);
        }

        /// <summary>
        /// The end user's own tickets - the "My Tickets" panel.
        ///
        /// Scoped server-side to the caller's identity. The client cannot ask
        /// for someone else's list, because it does not supply a user at all:
        /// the identity comes from the JWT, never from a parameter.
        /// </summary>
        [HttpGet, Route("tickets/mine")]
        public async Task<IHttpActionResult> GetMyTickets(
            bool onlyOpen = false, int pageNumber = 1, int pageSize = 25,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var ctx = ErrorContext.Values;
            if (!IsAuthenticated() || !ErpUser.IsReal(UserProfileId(ctx)))
                return Ok(new { items = new object[0], total = 0 });

            var items = await _store.ListTicketsForUserAsync(
                UserProfileId(ctx), onlyOpen, pageNumber, pageSize, cancellationToken)
                .ConfigureAwait(false);

            return Ok(new { items, total = items.Count });
        }

        /// <summary>
        /// One of the caller's own tickets, in end-user form: customer-visible
        /// history and comments only, no diagnostics, no assignee, no
        /// fingerprint.
        ///
        /// The filtering happens in the stored procedure
        /// (usp_Ticket_GetDetail @ForEndUser = 1), not here and not in the
        /// template. Filtering in the UI would still have sent the data to the
        /// browser, where anyone can read it in the network tab.
        /// </summary>
        [HttpGet, Route("tickets/{ticketNumber}")]
        public async Task<IHttpActionResult> GetMyTicket(
            string ticketNumber, CancellationToken cancellationToken)
        {
            var ctx = ErrorContext.Values;
            if (!IsAuthenticated()) return StatusCode(HttpStatusCode.Unauthorized);

            var detail = await _store.GetTicketForUserAsync(
                ticketNumber, UserProfileId(ctx), cancellationToken).ConfigureAwait(false);

            // 404, not 403, when the ticket exists but belongs to someone else.
            // A 403 confirms the number is real, which turns sequential ticket
            // numbers into an enumeration oracle.
            if (detail == null) return NotFound();

            return Ok(detail);
        }

        public class AddCommentRequest
        {
            public string CommentText { get; set; }
        }

        /// <summary>
        /// The end user replying on their own ticket.
        ///
        /// This is what makes "Waiting for Information" a conversation rather
        /// than a dead end: support asks a question, the user answers here, and
        /// the answer is on the ticket rather than in somebody's inbox.
        /// </summary>
        [HttpPost, Route("tickets/{ticketNumber}/comments")]
        public async Task<IHttpActionResult> AddMyComment(
            string ticketNumber, [FromBody] AddCommentRequest request, CancellationToken cancellationToken)
        {
            if (!IsAuthenticated()) return StatusCode(HttpStatusCode.Unauthorized);

            if (request == null || string.IsNullOrWhiteSpace(request.CommentText))
                return BadRequest("commentText is required.");

            var ctx = ErrorContext.Values;

            var ok = await _store.AddUserCommentAsync(
                ticketNumber, UserProfileId(ctx), ctx?.UserName,
                request.CommentText, cancellationToken).ConfigureAwait(false);

            if (!ok) return NotFound();
            return Ok(new { added = true });
        }

        /// <summary>
        /// The end user raising a ticket BY HAND, with no captured error and no
        /// Report Issue popup.
        ///
        /// Needed because plenty of real support requests have no exception
        /// behind them - "the totals on this report look wrong", "I cannot find
        /// the approve button". Nothing threw, so nothing was captured, and
        /// before this the schema could not represent the ticket at all.
        ///
        /// Not deduplicated, unlike an error-derived ticket. Fingerprint
        /// deduplication answers "is this the same fault?" and there is no
        /// fault here - two people describing the same annoyance in their own
        /// words are two requests, and merging them would discard one person's
        /// description.
        /// </summary>
        [HttpPost, Route("tickets/manual")]
        public async Task<IHttpActionResult> CreateManualTicket(
            [FromBody] ManualTicketRequest request, CancellationToken cancellationToken)
        {
            if (!IsAuthenticated()) return StatusCode(HttpStatusCode.Unauthorized);

            if (request == null || string.IsNullOrWhiteSpace(request.Title))
                return BadRequest("A title is required.");

            var ctx = ErrorContext.Values;

            // Ownership comes from the token. The [JsonIgnore] on these
            // properties means a client cannot set them even by sending them,
            // so nobody can raise a ticket in someone else's name.
            request.ReportedByUserProfileId = UserProfileId(ctx);
            request.ReportedByUserName = ctx?.UserName;
            request.ErpModule = request.ErpModule ?? ctx?.ErpModule;
            request.ReportedScreen = request.ReportedScreen ?? ctx?.Screen;
            request.CreatedVia = "user";

            if (!ErpUser.IsReal(request.ReportedByUserProfileId))
            {
                // Authenticated but we could not resolve who they are - so the
                // ticket would have no owner, appear in nobody's My Tickets,
                // and nobody could be asked for more detail.
                return Content(HttpStatusCode.Forbidden, new
                {
                    message = "Your account could not be identified, so the ticket was not created."
                });
            }

            var result = await _store.CreateManualTicketAsync(request, cancellationToken)
                .ConfigureAwait(false);

            if (result == null)
                return Content(HttpStatusCode.ServiceUnavailable,
                    new { message = "The ticket could not be created. Please try again." });

            return Ok(result);
        }

        /// <summary>The category list for the "create ticket" form.</summary>
        [HttpGet, Route("request-categories")]
        public async Task<IHttpActionResult> RequestCategories(CancellationToken cancellationToken)
        {
            var items = await _store.ListRequestCategoriesAsync(cancellationToken).ConfigureAwait(false);
            return Ok(new { items });
        }

        /* =================================================== plumbing ==== */

        /// <summary>
        /// Is this request authenticated?
        ///
        /// Reads the principal the ERP's own JWT middleware established -
        /// the framework never validates a token itself. Writing a second token
        /// validator would mean a second place to get signing keys, clock skew
        /// and issuer checks wrong, and it could disagree with the ERP's, which
        /// is worse than not checking at all.
        /// </summary>
        /// <summary>
        /// The caller's ERP UserProfileID, or -1.
        ///
        /// Read from the request context the correlation handler established -
        /// never from a route, query string or body. A user id that the client
        /// can set is not an identity, it is a suggestion, and every "my
        /// tickets" endpoint here is only as safe as this one value.
        /// </summary>
        private static int UserProfileId(ErrorContext.ErrorContextValues ctx) =>
            ErpUser.Normalize(ctx?.UserProfileId ?? ErpUser.None);

        private bool IsAuthenticated()
        {
            try
            {
                var principal = User ?? HttpContext.Current?.User ?? Thread.CurrentPrincipal;
                return principal?.Identity != null && principal.Identity.IsAuthenticated;
            }
            catch
            {
                return false;
            }
        }

        private string GetClientIp()
        {
            try
            {
                return HttpContext.Current?.Request?.UserHostAddress;
            }
            catch
            {
                return null;
            }
        }

        /// <summary>
        /// Throttle key for an anonymous caller.
        ///
        /// The DIRECT remote address, not X-Forwarded-For. A forwarded header is
        /// attacker-controlled, so keying on it lets one client mint a fresh
        /// bucket per request and bypass the limit entirely - and fill the
        /// bucket dictionary while doing it. If the ERP genuinely sits behind a
        /// reverse proxy, configure the proxy's real-IP module so
        /// UserHostAddress is already correct, rather than trusting the header
        /// here.
        /// </summary>
        private string ThrottleKey()
        {
            return GetClientIp() ?? "(unknown)";
        }
    }
}
