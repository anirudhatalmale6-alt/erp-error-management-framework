using System;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Claims;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Http.Controllers;
using System.Web.Http.Filters;

namespace Erp.ErrorManagement.WebApi2
{
    /// <summary>
    /// Gate on the support console API.
    ///
    /// Two layers, on purpose:
    ///
    ///   1. AUTHENTICATION - the ERP's own JWT middleware. If the request has no
    ///      authenticated principal it never reaches the controller.
    ///   2. AUTHORISATION - this filter, which resolves the caller against the
    ///      ERM support roster (and optionally a token role claim) and
    ///      checks the specific capability the action needs.
    ///
    /// Both matter. A route guard in Angular hides a screen; it does not protect
    /// an endpoint. Anyone who can open the browser console can call
    /// /api/error-management/admin/errors directly, and the error store holds
    /// every stack trace, SQL object name and user name in the system - it is
    /// the single most useful thing in the ERP for someone probing it. So the
    /// enforcement is server-side, per action, and the UI guard is only there so
    /// that people who cannot use the console are not shown a menu item.
    ///
    /// The filter FAILS CLOSED. If the roster cannot be read, the answer is no.
    /// That is the opposite of every other failure path in this framework -
    /// everywhere else, losing an error record beats breaking the ERP - and the
    /// asymmetry is deliberate: an authorisation check that fails open during a
    /// database blip is not a check.
    /// </summary>
    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, AllowMultiple = false)]
    public class RequiresSupportAttribute : Attribute
    {
        public RequiresSupportAttribute(SupportCapability capability)
        {
            Capability = capability;
        }

        public SupportCapability Capability { get; }
    }

    public class ErpAdminAuthorizationFilter : IAuthenticationFilter
    {
        private readonly ISupportDirectory _directory;
        private readonly ErrorCaptureOptions _options;

        public ErpAdminAuthorizationFilter(ISupportDirectory directory, ErrorCaptureOptions options)
        {
            _directory = directory ?? throw new ArgumentNullException(nameof(directory));
            _options = options ?? throw new ArgumentNullException(nameof(options));
        }

        public bool AllowMultiple => false;

        /// <summary>Key under which the resolved identity is stashed for the action.</summary>
        public const string IdentityKey = "ERM.SupportIdentity";

        public async Task AuthenticateAsync(HttpAuthenticationContext context, CancellationToken cancellationToken)
        {
            var descriptor = context.ActionContext?.ActionDescriptor;

            // Work out which capability this action needs. Method-level wins
            // over controller-level.
            var attribute =
                descriptor?.GetCustomAttributes<RequiresSupportAttribute>().FirstOrDefault()
                ?? descriptor?.ControllerDescriptor?.GetCustomAttributes<RequiresSupportAttribute>().FirstOrDefault();

            // No attribute = not an admin action; this filter has no opinion.
            if (attribute == null) return;

            var request = context.Request;

            var principal = context.Principal ?? Thread.CurrentPrincipal;
            if (principal?.Identity == null || !principal.Identity.IsAuthenticated)
            {
                // 401, not 403: the caller has not identified themselves at all,
                // so the correct advice is "authenticate", not "you may not".
                context.ErrorResult = new StatusCodeResult(HttpStatusCode.Unauthorized, request);
                return;
            }

            var userId = ReadClaim(principal, ClaimTypes.NameIdentifier)
                         ?? ReadClaim(principal, "sub")
                         ?? ReadClaim(principal, "uid");
            var userName = principal.Identity.Name;

            SupportIdentity identity;

            // Optional short-circuit: a token role that grants access without a
            // roster row. Off unless SupportRoleClaims is configured.
            if (_options.SupportRoleClaims != null && _options.SupportRoleClaims.Count > 0
                && HasConfiguredRole(principal))
            {
                identity = new SupportIdentity
                {
                    IsSupportUser = true,
                    UserId = userId,
                    UserName = userName,
                    DisplayName = userName,
                    RoleCode = _options.ClaimAuthorisedRoleCode,
                    RoleName = _options.ClaimAuthorisedRoleCode,
                    CanViewErrors = true,
                    CanViewDiagnostics = true,
                    CanManageTickets = true,
                    CanBeAssigned = true,
                    CanTriage = true,
                    CanConfigure = true
                };
            }
            else
            {
                identity = await _directory.ResolveAsync(userId, userName, cancellationToken)
                    .ConfigureAwait(false);
            }

            if (!identity.Has(attribute.Capability))
            {
                // 403 with no detail about WHY. Telling an unauthorised caller
                // which capability they lack maps out the permission model for
                // them at no cost.
                context.ErrorResult = new StatusCodeResult(HttpStatusCode.Forbidden, request);
                return;
            }

            // Stash it so the action does not have to resolve it again - one
            // round trip per request, not per check.
            request.Properties[IdentityKey] = identity;
        }

        public Task ChallengeAsync(HttpAuthenticationChallengeContext context, CancellationToken cancellationToken)
        {
            return Task.FromResult(0);
        }

        private bool HasConfiguredRole(System.Security.Principal.IPrincipal principal)
        {
            try
            {
                if (principal is ClaimsPrincipal claims)
                {
                    foreach (var role in _options.SupportRoleClaims)
                    {
                        if (claims.HasClaim(_options.RoleClaimType, role)) return true;
                        // Also honour the framework's own IsInRole, which some
                        // token handlers wire up instead of raw claims.
                        if (principal.IsInRole(role)) return true;
                    }
                    return false;
                }

                return _options.SupportRoleClaims.Any(principal.IsInRole);
            }
            catch
            {
                // Fail closed, as above.
                return false;
            }
        }

        private static string ReadClaim(System.Security.Principal.IPrincipal principal, string type)
        {
            return (principal as ClaimsPrincipal)?.Claims
                .FirstOrDefault(c => string.Equals(c.Type, type, StringComparison.OrdinalIgnoreCase))?.Value;
        }
    }

    /// <summary>Minimal IHttpActionResult for a bare status code.</summary>
    internal class StatusCodeResult : System.Web.Http.IHttpActionResult
    {
        private readonly HttpStatusCode _status;
        private readonly HttpRequestMessage _request;

        public StatusCodeResult(HttpStatusCode status, HttpRequestMessage request)
        {
            _status = status;
            _request = request;
        }

        public Task<HttpResponseMessage> ExecuteAsync(CancellationToken cancellationToken)
        {
            var response = new HttpResponseMessage(_status);
            if (_request != null) response.RequestMessage = _request;
            return Task.FromResult(response);
        }
    }
}
