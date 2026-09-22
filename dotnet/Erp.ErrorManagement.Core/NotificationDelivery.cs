using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Net;
using System.Net.Mail;
using System.Threading;
using System.Threading.Tasks;

namespace Erp.ErrorManagement
{
    /// <summary>
    /// One notification waiting to be delivered, as claimed from the outbox.
    /// </summary>
    public class PendingNotification
    {
        public long OutboxId { get; set; }
        public int RecipientUserProfileId { get; set; }
        public string EventKind { get; set; }
        public string TicketNumber { get; set; }
        public string Title { get; set; }
        public string Body { get; set; }
        public string LinkUrl { get; set; }
        public int AttemptCount { get; set; }
    }

    /// <summary>
    /// Where a notification actually goes.
    ///
    /// The framework does not care. It hands over a recipient, a title and a
    /// body, and something else decides whether that becomes an email, a row in
    /// the ERP's own notification table, or both. Implement this if neither
    /// shipped sender fits.
    /// </summary>
    public interface INotificationSender
    {
        /// <summary>
        /// Deliver one notification. Return false with a reason rather than
        /// throwing for an expected condition - "this user has no email
        /// address" is an answer, not a fault. Throwing is for genuine
        /// failures; the dispatcher catches those and records them too.
        /// </summary>
        Task<NotificationResult> SendAsync(PendingNotification notification, CancellationToken ct = default);
    }

    public class NotificationResult
    {
        public bool Delivered { get; set; }
        public string FailureReason { get; set; }

        public static NotificationResult Ok() => new NotificationResult { Delivered = true };

        public static NotificationResult Fail(string reason) =>
            new NotificationResult { Delivered = false, FailureReason = reason };
    }

    /// <summary>
    /// SMTP settings. Nothing here is stored in the database on purpose - a
    /// mail password in a table is a mail password in every backup, and in the
    /// error store specifically, which is the one place support staff can read.
    /// </summary>
    public class SmtpNotificationOptions
    {
        public string Host { get; set; }
        public int Port { get; set; } = 587;

        /// <summary>
        /// STARTTLS on 587. Set false only for an internal relay that does not
        /// offer TLS - and then know that credentials cross the network in the
        /// clear, so use an unauthenticated relay restricted by IP instead.
        /// </summary>
        public bool UseStartTls { get; set; } = true;

        public string UserName { get; set; }
        public string Password { get; set; }

        public string FromAddress { get; set; }
        public string FromDisplayName { get; set; } = "ERP Support";

        public int TimeoutSeconds { get; set; } = 20;

        /// <summary>
        /// Resolve an ERP UserProfileID to an email address.
        ///
        /// REQUIRED, and deliberately not implemented here: the framework never
        /// reads your ERP's user tables - that is the isolation rule the whole
        /// design rests on - and it does not keep a copy of your user
        /// directory, because a second copy of anything is a second thing to
        /// keep in step.
        ///
        /// Return null when there is no address. That is recorded as an
        /// undelivered notification with a reason, not as an error.
        /// </summary>
        public Func<int, string> EmailAddressResolver { get; set; }

        /// <summary>
        /// Send every notification here instead of to the real recipient.
        /// Set this in Test. Without it, a test run with production data
        /// emails real users about tickets that do not exist.
        /// </summary>
        public string RedirectAllMailTo { get; set; }

        public void Validate()
        {
            if (string.IsNullOrWhiteSpace(Host))
                throw new InvalidOperationException("SmtpNotificationOptions.Host is required.");
            if (string.IsNullOrWhiteSpace(FromAddress))
                throw new InvalidOperationException("SmtpNotificationOptions.FromAddress is required.");
            if (EmailAddressResolver == null)
                throw new InvalidOperationException(
                    "SmtpNotificationOptions.EmailAddressResolver is required - the framework " +
                    "cannot map a UserProfileID to an email address without reading your ERP, " +
                    "which it deliberately does not do.");
        }
    }

    /// <summary>
    /// Delivers notifications as email.
    ///
    /// Plain text, not HTML, and deliberately so: these messages say "your issue
    /// has been updated", they are read on a phone, and an HTML template is one
    /// more thing that can render badly or carry content it should not. The body
    /// is already safe user-facing text - the framework never puts a stack trace
    /// or a SQL object name in it.
    /// </summary>
    public class SmtpNotificationSender : INotificationSender
    {
        private readonly SmtpNotificationOptions _options;
        private readonly Action<string, Exception> _log;

        public SmtpNotificationSender(SmtpNotificationOptions options,
            Action<string, Exception> log = null)
        {
            _options = options ?? throw new ArgumentNullException(nameof(options));
            _options.Validate();
            _log = log;
        }

        public async Task<NotificationResult> SendAsync(PendingNotification notification,
            CancellationToken ct = default)
        {
            if (notification == null) return NotificationResult.Fail("No notification supplied.");

            string to;
            try
            {
                to = _options.EmailAddressResolver(notification.RecipientUserProfileId);
            }
            catch (Exception ex)
            {
                // The host's resolver threw. That is a fault, not "no address".
                return NotificationResult.Fail($"Email resolver failed: {ex.Message}");
            }

            if (string.IsNullOrWhiteSpace(to))
                return NotificationResult.Fail(
                    $"No email address for UserProfileID {notification.RecipientUserProfileId}.");

            var actualTo = string.IsNullOrWhiteSpace(_options.RedirectAllMailTo)
                ? to
                : _options.RedirectAllMailTo;

            try
            {
                using (var message = new MailMessage())
                using (var client = new SmtpClient(_options.Host, _options.Port))
                {
                    message.From = new MailAddress(_options.FromAddress, _options.FromDisplayName);
                    message.To.Add(actualTo);
                    message.Subject = Subject(notification);
                    message.Body = BuildBody(notification, to, actualTo);
                    message.IsBodyHtml = false;

                    client.EnableSsl = _options.UseStartTls;
                    client.Timeout = _options.TimeoutSeconds * 1000;

                    if (!string.IsNullOrEmpty(_options.UserName))
                    {
                        client.UseDefaultCredentials = false;
                        client.Credentials = new NetworkCredential(_options.UserName, _options.Password);
                    }

                    await Task.Run(() => client.Send(message), ct).ConfigureAwait(false);
                }

                return NotificationResult.Ok();
            }
            catch (SmtpException ex)
            {
                // The status code is the useful half - it distinguishes "mailbox
                // does not exist" (never going to work, stop retrying) from
                // "service unavailable" (try again in a minute).
                _log?.Invoke($"ERM: SMTP send failed for outbox {notification.OutboxId}", ex);
                return NotificationResult.Fail($"SMTP {ex.StatusCode}: {ex.Message}");
            }
            catch (Exception ex)
            {
                _log?.Invoke($"ERM: notification send failed for outbox {notification.OutboxId}", ex);
                return NotificationResult.Fail($"{ex.GetType().Name}: {ex.Message}");
            }
        }

        private static string Subject(PendingNotification n) =>
            string.IsNullOrWhiteSpace(n.TicketNumber)
                ? n.Title
                : $"[{n.TicketNumber}] {n.Title}";

        private string BuildBody(PendingNotification n, string intendedTo, string actualTo)
        {
            var body = n.Body ?? string.Empty;

            if (!string.IsNullOrWhiteSpace(n.TicketNumber))
                body += $"{Environment.NewLine}{Environment.NewLine}Reference: {n.TicketNumber}";

            if (!string.IsNullOrWhiteSpace(n.LinkUrl))
                body += $"{Environment.NewLine}{n.LinkUrl}";

            // If mail is being redirected, say so IN the mail. A redirected copy
            // that looks identical to the real thing is how a test message gets
            // forwarded to a customer.
            if (!string.Equals(intendedTo, actualTo, StringComparison.OrdinalIgnoreCase))
                body = $"[TEST REDIRECT - this was addressed to {intendedTo}]" +
                       $"{Environment.NewLine}{Environment.NewLine}{body}";

            return body;
        }
    }

    /// <summary>
    /// Pulls claimed notifications out of the outbox, hands each to a sender,
    /// and reports the outcome back.
    ///
    /// Call <see cref="RunOnceAsync"/> from a scheduled task, a hosted service,
    /// or SQL Agent invoking a small console app. There is no timer in here -
    /// the framework should not decide how often your ERP does background work.
    /// </summary>
    public class NotificationDispatcher
    {
        private readonly ErrorCaptureOptions _options;
        private readonly INotificationSender _sender;
        private readonly string _claimedBy;

        public NotificationDispatcher(ErrorCaptureOptions options, INotificationSender sender,
            string claimedBy = null)
        {
            _options = options ?? throw new ArgumentNullException(nameof(options));
            _sender = sender ?? throw new ArgumentNullException(nameof(sender));
            _options.Validate();

            _claimedBy = claimedBy ?? SafeMachineName();
        }

        /// <summary>
        /// One pass. Returns how many were sent and how many failed.
        ///
        /// Never throws: this runs in the background, and a dispatcher that dies
        /// on one malformed row stops delivering everything behind it.
        /// </summary>
        public async Task<DispatchSummary> RunOnceAsync(int batchSize = 50, int maxAttempts = 5,
            CancellationToken ct = default)
        {
            var summary = new DispatchSummary();

            try
            {
                await ReleaseStaleAsync(ct).ConfigureAwait(false);

                var claimed = await ClaimAsync(batchSize, maxAttempts, ct).ConfigureAwait(false);

                foreach (var item in claimed)
                {
                    NotificationResult result;
                    try
                    {
                        result = await _sender.SendAsync(item, ct).ConfigureAwait(false)
                                 ?? NotificationResult.Fail("Sender returned null.");
                    }
                    catch (Exception ex)
                    {
                        result = NotificationResult.Fail($"Sender threw: {ex.Message}");
                    }

                    // Reported even when sending threw, so a claimed row never
                    // stays stuck in 'sending' waiting for the stale sweep.
                    await MarkResultAsync(item.OutboxId, result, maxAttempts, ct).ConfigureAwait(false);

                    if (result.Delivered) summary.Sent++;
                    else summary.Failed++;
                }
            }
            catch (Exception ex)
            {
                summary.Error = ex.Message;
                _options.FallbackLogger?.Invoke("ERM: notification dispatch pass failed", ex);
            }

            return summary;
        }

        private async Task<List<PendingNotification>> ClaimAsync(int batchSize, int maxAttempts,
            CancellationToken ct)
        {
            var result = new List<PendingNotification>();

            using (var connection = new SqlConnection(_options.ConnectionString))
            using (var command = new SqlCommand("ERM.usp_Notification_Claim", connection))
            {
                command.CommandType = CommandType.StoredProcedure;
                command.CommandTimeout = _options.CommandTimeoutSeconds;
                command.Parameters.Add("@BatchSize", SqlDbType.Int).Value = batchSize;
                command.Parameters.Add("@MaxAttempts", SqlDbType.Int).Value = maxAttempts;
                command.Parameters.Add("@ClaimedBy", SqlDbType.NVarChar, 128).Value =
                    (object)_claimedBy ?? DBNull.Value;

                await connection.OpenAsync(ct).ConfigureAwait(false);
                using (var reader = await command.ExecuteReaderAsync(ct).ConfigureAwait(false))
                {
                    while (await reader.ReadAsync(ct).ConfigureAwait(false))
                    {
                        result.Add(new PendingNotification
                        {
                            OutboxId = Convert.ToInt64(reader["ERM_NotificationOutboxID"]),
                            RecipientUserProfileId = Convert.ToInt32(reader["RecipientUserProfileID"]),
                            EventKind = Str(reader, "EventKind"),
                            TicketNumber = Str(reader, "TicketNumber"),
                            Title = Str(reader, "Title"),
                            Body = Str(reader, "Body"),
                            LinkUrl = Str(reader, "LinkUrl"),
                            AttemptCount = Convert.ToInt32(reader["AttemptCount"]),
                        });
                    }
                }
            }

            return result;
        }

        private async Task MarkResultAsync(long outboxId, NotificationResult result, int maxAttempts,
            CancellationToken ct)
        {
            using (var connection = new SqlConnection(_options.ConnectionString))
            using (var command = new SqlCommand("ERM.usp_Notification_MarkResult", connection))
            {
                command.CommandType = CommandType.StoredProcedure;
                command.CommandTimeout = _options.CommandTimeoutSeconds;
                command.Parameters.Add("@ERM_NotificationOutboxID", SqlDbType.BigInt).Value = outboxId;
                command.Parameters.Add("@Delivered", SqlDbType.Bit).Value = result.Delivered;
                command.Parameters.Add("@FailureReason", SqlDbType.NVarChar, 2000).Value =
                    (object)result.FailureReason ?? DBNull.Value;
                command.Parameters.Add("@MaxAttempts", SqlDbType.Int).Value = maxAttempts;

                await connection.OpenAsync(ct).ConfigureAwait(false);
                await command.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            }
        }

        private async Task ReleaseStaleAsync(CancellationToken ct)
        {
            using (var connection = new SqlConnection(_options.ConnectionString))
            using (var command = new SqlCommand("ERM.usp_Notification_ReleaseStale", connection))
            {
                command.CommandType = CommandType.StoredProcedure;
                command.CommandTimeout = _options.CommandTimeoutSeconds;

                await connection.OpenAsync(ct).ConfigureAwait(false);
                await command.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            }
        }

        private static string Str(IDataRecord r, string name)
        {
            var i = r.GetOrdinal(name);
            return r.IsDBNull(i) ? null : Convert.ToString(r.GetValue(i));
        }

        private static string SafeMachineName()
        {
            try { return Environment.MachineName; }
            catch { return null; }
        }
    }

    public class DispatchSummary
    {
        public int Sent { get; set; }
        public int Failed { get; set; }
        public string Error { get; set; }
    }
}
