using System;
using System.Collections.Concurrent;

namespace Erp.ErrorManagement
{
    /// <summary>
    /// Rate limiter for the UNAUTHENTICATED capture endpoint.
    ///
    /// Capturing errors from public/unauthenticated pages means the capture
    /// endpoint has to accept anonymous POSTs. That is a real requirement - an
    /// error on a public login or self-service page is exactly the kind you most
    /// need to see - but it also means anyone on the internet can write rows
    /// into the error store, at whatever rate they like.
    ///
    /// Without a limit, three things happen, in this order:
    ///   1. The error store fills with junk and the recurring-problem report
    ///      becomes unreadable.
    ///   2. ERM grows until it affects the ERP database it shares a disk
    ///      with, which is the framework harming the application it exists to
    ///      protect.
    ///   3. Nobody notices for weeks, because the whole design is that capture
    ///      failures stay quiet.
    ///
    /// So anonymous capture is rate-limited per client IP with a token bucket.
    /// AUTHENTICATED capture is deliberately NOT limited: a signed-in user
    /// triggering 500 errors is a genuine incident and throttling it would
    /// discard the evidence of the worst thing happening that day.
    ///
    /// The bucket is per-process and in-memory on purpose. It is a guard rail,
    /// not an access control, and it must never add a dependency (Redis, a
    /// database round trip) to the path taken when the application is already
    /// failing. Behind a load balancer each node keeps its own bucket; the
    /// effective limit is the per-node limit times the node count, which is
    /// fine for something whose job is to stop a flood rather than meter usage.
    /// </summary>
    public class AnonymousCaptureThrottle
    {
        private class Bucket
        {
            public double Tokens;
            public DateTime LastRefillUtc;
        }

        private readonly ConcurrentDictionary<string, Bucket> _buckets =
            new ConcurrentDictionary<string, Bucket>(StringComparer.OrdinalIgnoreCase);

        private readonly int _burst;
        private readonly double _refillPerSecond;
        private readonly int _maxTrackedClients;

        private DateTime _lastSweepUtc = DateTime.UtcNow;

        /// <param name="envelopesPerMinute">Sustained rate allowed per client IP.</param>
        /// <param name="burst">Bucket size - how many may arrive at once.</param>
        /// <param name="maxTrackedClients">
        /// Hard cap on distinct IPs held in memory. Without it, a spoofed
        /// X-Forwarded-For per request would turn this protective measure into
        /// an unbounded dictionary - a memory leak wearing a rate limiter's hat.
        /// </param>
        public AnonymousCaptureThrottle(
            int envelopesPerMinute = 60,
            int burst = 20,
            int maxTrackedClients = 20000)
        {
            if (envelopesPerMinute < 1) envelopesPerMinute = 1;
            if (burst < 1) burst = 1;

            _burst = burst;
            _refillPerSecond = envelopesPerMinute / 60.0;
            _maxTrackedClients = maxTrackedClients < 1000 ? 1000 : maxTrackedClients;
        }

        /// <summary>
        /// Try to consume <paramref name="count"/> tokens for this client.
        /// Returns how many were actually granted - a batch of 10 may be
        /// partially accepted, which is better than dropping all 10.
        /// </summary>
        public int TryAcquire(string clientKey, int count)
        {
            if (count <= 0) return 0;

            var key = string.IsNullOrWhiteSpace(clientKey) ? "(unknown)" : clientKey;
            var now = DateTime.UtcNow;

            SweepIfNeeded(now);

            var bucket = _buckets.GetOrAdd(key, _ => new Bucket { Tokens = _burst, LastRefillUtc = now });

            lock (bucket)
            {
                var elapsedSeconds = (now - bucket.LastRefillUtc).TotalSeconds;
                if (elapsedSeconds > 0)
                {
                    bucket.Tokens = Math.Min(_burst, bucket.Tokens + elapsedSeconds * _refillPerSecond);
                    bucket.LastRefillUtc = now;
                }

                var granted = (int)Math.Floor(Math.Min(count, bucket.Tokens));
                if (granted > 0) bucket.Tokens -= granted;
                return granted;
            }
        }

        /// <summary>
        /// Drop buckets that have fully refilled - a full bucket is
        /// indistinguishable from a client that has never been seen, so keeping
        /// it costs memory and buys nothing.
        /// </summary>
        private void SweepIfNeeded(DateTime now)
        {
            if (_buckets.Count < _maxTrackedClients && (now - _lastSweepUtc).TotalMinutes < 5) return;

            lock (_buckets)
            {
                if ((now - _lastSweepUtc).TotalSeconds < 30 && _buckets.Count < _maxTrackedClients) return;
                _lastSweepUtc = now;

                foreach (var pair in _buckets)
                {
                    var b = pair.Value;
                    bool idle;
                    lock (b)
                    {
                        var elapsed = (now - b.LastRefillUtc).TotalSeconds;
                        idle = b.Tokens + elapsed * _refillPerSecond >= _burst;
                    }
                    if (idle) _buckets.TryRemove(pair.Key, out _);
                }

                // Still over the cap after sweeping means a spoofed-key flood.
                // Clear outright: a rate limiter that runs the process out of
                // memory has become the outage it was meant to prevent.
                if (_buckets.Count >= _maxTrackedClients) _buckets.Clear();
            }
        }

        /// <summary>Diagnostics only.</summary>
        public int TrackedClientCount => _buckets.Count;
    }
}
