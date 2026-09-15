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
    /// Drop this file into the existing Web API 2 project (or reference this
    /// assembly and let attribute routing find it) and the browser side has
    /// somewhere to post to.  No other controller changes.
    /// </summary>
    [RoutePrefix("api/error-management")]
    public class ErrorManagementController : ApiController
    {
        private readonly ErrorCaptureService _capture;
        private readonly IErrorStore _store;

        public ErrorManagementController(ErrorCaptureService capture, IErrorStore store)
        {
            _capture = capture ?? throw new ArgumentNullException(nameof(capture));
            _store = store ?? throw new ArgumentNullException(nameof(store));
        }

        /// <summary>
        /// Batched capture from the browser.  Returns one result per envelope,
        /// IN THE SAME ORDER, because the client matches them positionally.
        /// </summary>
        [HttpPost, Route("errors")]
        public async Task<IHttpActionResult> CaptureErrors(
            [FromBody] List<ErrorEnvelope> envelopes, CancellationToken cancellationToken)
        {
            if (envelopes == null || envelopes.Count == 0) return Ok(new List<ErrorCaptureResult>());

            // Bound the batch: this endpoint is reachable by anything that can
            // reach the ERP, and an unbounded list here is a free denial of
            // service against the error store.
            if (envelopes.Count > 50) envelopes = envelopes.Take(50).ToList();

            var clientIp = GetClientIp();
            var results = new List<ErrorCaptureResult>(envelopes.Count);

            foreach (var envelope in envelopes)
            {
                var result = await _capture
                    .CaptureClientEnvelopeAsync(envelope, clientIp, cancellationToken)
                    .ConfigureAwait(false);

                // A null result still occupies its slot, or every subsequent
                // envelope in the batch would be matched to the wrong reference.
                results.Add(result ?? new ErrorCaptureResult { ShouldNotifyUser = true });
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
            if (envelopes != null)
            {
                var clientIp = GetClientIp();
                foreach (var envelope in envelopes.Take(50))
                {
                    await _capture.CaptureClientEnvelopeAsync(envelope, clientIp, cancellationToken)
                        .ConfigureAwait(false);
                }
            }

            // 204: sendBeacon ignores the body, and returning one wastes bytes
            // on a connection the browser is about to drop.
            return StatusCode(HttpStatusCode.NoContent);
        }

        public class CreateTicketRequest
        {
            public string ErrorReference { get; set; }
            public string UserDescription { get; set; }
        }

        [HttpPost, Route("tickets")]
        public async Task<IHttpActionResult> CreateTicket(
            [FromBody] CreateTicketRequest request, CancellationToken cancellationToken)
        {
            if (request == null || string.IsNullOrWhiteSpace(request.ErrorReference))
                return BadRequest("errorReference is required.");

            var ctx = ErrorContext.Values;

            var result = await _store.CreateTicketAsync(
                request.ErrorReference,
                request.UserDescription,
                ctx?.UserId,
                ctx?.UserName,
                cancellationToken).ConfigureAwait(false);

            if (result == null)
                return Content(HttpStatusCode.ServiceUnavailable,
                    new { message = "The ticket could not be created. Your error has still been recorded." });

            return Ok(result);
        }

        private string GetClientIp()
        {
            try
            {
                var context = HttpContext.Current;
                return context?.Request?.UserHostAddress;
            }
            catch
            {
                return null;
            }
        }
    }
}
