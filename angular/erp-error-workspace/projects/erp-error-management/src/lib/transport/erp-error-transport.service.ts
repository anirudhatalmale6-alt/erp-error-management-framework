import { HttpBackend, HttpClient, HttpContext, HttpContextToken, HttpHeaders } from '@angular/common/http';
import { Injectable, NgZone, inject } from '@angular/core';
import { Observable, Subject, of } from 'rxjs';
import { catchError, timeout } from 'rxjs/operators';
import { ERP_ERROR_CONFIG } from '../config/erp-error-config';
import {
  ErpErrorCaptureResult,
  ErpErrorEnvelope,
  ErpTicketCreateResult,
  ErpTicketSummary,
} from '../models/error-envelope';

/**
 * Marks a request as originating from the error framework itself, so the
 * capture interceptor can skip it.  Without this the framework reports its own
 * failures to itself and loops until the browser tab dies.
 */
export const ERP_ERROR_INTERNAL_REQUEST = new HttpContextToken<boolean>(() => false);

export function internalContext(): HttpContext {
  return new HttpContext().set(ERP_ERROR_INTERNAL_REQUEST, true);
}

/**
 * Buffers envelopes and delivers them to the API.
 *
 * Design constraints, all from the brief's "the framework must not
 * interrupt or negatively affect the ERP if an error-management operation
 * fails":
 *
 *  - Uses HttpBackend, NOT HttpClient, so it bypasses the host application's
 *    entire interceptor chain.  An auth interceptor that redirects on 401, a
 *    loading-spinner interceptor, a retry interceptor - none of them see these
 *    requests, and none of them can be broken by them.
 *  - Runs outside the Angular zone: capture never triggers change detection and
 *    so cannot itself provoke a render error.
 *  - Every failure path ends in a swallowed error.  There is no code path in
 *    this class that can throw into the host application.
 *  - Persists the queue to localStorage, so the error that killed the tab still
 *    arrives after the reload.
 */
@Injectable({ providedIn: 'root' })
export class ErpErrorTransportService {
  private readonly config = inject(ERP_ERROR_CONFIG);
  private readonly zone = inject(NgZone);
  private readonly backend = inject(HttpBackend);
  /** Built on HttpBackend on purpose - see the class comment. */
  private readonly http = new HttpClient(this.backend);

  private queue: ErpErrorEnvelope[] = [];
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  private retryIndex = 0;
  private sending = false;

  /** Emits every capture result so the dialog can show the reference number. */
  readonly captured$ = new Subject<{ envelope: ErpErrorEnvelope; result: ErpErrorCaptureResult }>();

  constructor() {
    this.restoreQueue();
    this.installUnloadFlush();
    if (this.queue.length) this.scheduleFlush(0);
  }

  /**
   * Fire-and-forget enqueue.  Returns a promise that resolves with the capture
   * result when the envelope reaches the server, or null if it was buffered,
   * dropped or the send failed.  Callers that need the reference number for a
   * dialog await it; callers that do not, ignore it.
   */
  enqueue(envelope: ErpErrorEnvelope): Promise<ErpErrorCaptureResult | null> {
    try {
      if (this.queue.length >= this.config.maxQueueSize) {
        // Drop the OLDEST.  During a cascading failure the newest errors are
        // the ones that describe how it ended; the first 200 all say the same
        // thing anyway (and their fingerprint count is already incremented
        // server-side by whichever ones did get through).
        this.queue.shift();
      }
      this.queue.push(envelope);
      this.persistQueue();

      // Severe errors go now; everything else rides the next batch window.
      const immediate = envelope.severity === 'critical' || envelope.severity === 'high';
      return this.scheduleFlush(immediate ? 0 : this.config.flushIntervalMs, envelope);
    } catch {
      return Promise.resolve(null);
    }
  }

  /** Raise a ticket from a captured error. */
  createTicket(errorReference: string, userDescription?: string | null): Observable<ErpTicketCreateResult | null> {
    return this.http
      .post<ErpTicketCreateResult>(
        `${this.base()}/tickets`,
        { errorReference, userDescription: userDescription ?? null },
        { context: internalContext(), headers: this.jsonHeaders() },
      )
      .pipe(
        timeout(15000),
        catchError(() => of(null)),
      );
  }

  /** The end user's own tickets, for the "track my issue" screen. */
  getMyTickets(onlyOpen = false): Observable<ErpTicketSummary[]> {
    return this.http
      .get<{ items: ErpTicketSummary[] }>(`${this.base()}/tickets/mine?onlyOpen=${onlyOpen}`, {
        context: internalContext(),
      })
      .pipe(
        timeout(15000),
        catchError(() => of({ items: [] })),
      ) as unknown as Observable<ErpTicketSummary[]>;
  }

  getTicket(ticketNumber: string): Observable<unknown | null> {
    return this.http
      .get(`${this.base()}/tickets/${encodeURIComponent(ticketNumber)}`, { context: internalContext() })
      .pipe(
        timeout(15000),
        catchError(() => of(null)),
      );
  }

  private base(): string {
    return this.config.apiBaseUrl.replace(/\/+$/, '');
  }

  private jsonHeaders(): HttpHeaders {
    return new HttpHeaders({ 'Content-Type': 'application/json' });
  }

  /**
   * Queue an envelope and return a promise for ITS capture result.
   *
   * Resolvers are keyed by envelope identity rather than by position in a
   * batch: a batch can be partially acknowledged, re-ordered by a retry, or
   * split across two flushes, and an index-based mapping would then hand the
   * caller somebody else's reference number - which is the one thing worse
   * than handing them none.
   */
  private readonly resolvers = new Map<ErpErrorEnvelope, (r: ErpErrorCaptureResult | null) => void>();

  private scheduleFlush(
    delayMs: number,
    awaited?: ErpErrorEnvelope,
  ): Promise<ErpErrorCaptureResult | null> {
    const promise = awaited
      ? new Promise<ErpErrorCaptureResult | null>((resolve) => this.resolvers.set(awaited, resolve))
      : Promise.resolve(null);

    this.scheduleFlushInternal(delayMs);
    return promise;
  }

  private async flush(): Promise<void> {
    if (this.sending || this.queue.length === 0) return;
    this.sending = true;

    const batch = this.queue.slice(0, this.config.batchSize);

    try {
      const results = await this.post(batch);

      if (results) {
        // Only drop what the server actually acknowledged.
        this.queue.splice(0, batch.length);
        this.persistQueue();
        this.retryIndex = 0;

        batch.forEach((envelope, i) => {
          const result = results[i] ?? null;
          if (result) this.captured$.next({ envelope, result });
          this.settle(envelope, result);
        });

        if (this.queue.length) this.scheduleFlushInternal(0);
      } else {
        // The capture endpoint is unreachable.  Keep the batch - losing the
        // evidence because the log server is down defeats the point - but
        // release the waiters now so the user is not left looking at a spinner.
        const delays = this.config.retryDelaysMs;
        const delay = delays[Math.min(this.retryIndex, delays.length - 1)];
        this.retryIndex++;
        batch.forEach((envelope) => this.settle(envelope, null));
        this.scheduleFlushInternal(delay);
      }
    } catch {
      batch.forEach((envelope) => this.settle(envelope, null));
    } finally {
      this.sending = false;
    }
  }

  private settle(envelope: ErpErrorEnvelope, result: ErpErrorCaptureResult | null): void {
    const resolve = this.resolvers.get(envelope);
    if (!resolve) return;
    this.resolvers.delete(envelope);
    try {
      resolve(result);
    } catch {
      /* a waiter must never break the flush loop */
    }
  }

  private scheduleFlushInternal(delayMs: number): void {
    this.zone.runOutsideAngular(() => {
      if (this.flushTimer !== null) clearTimeout(this.flushTimer);
      this.flushTimer = setTimeout(() => {
        this.flushTimer = null;
        void this.flush();
      }, delayMs);
    });
  }

  private post(batch: ErpErrorEnvelope[]): Promise<ErpErrorCaptureResult[] | null> {
    return new Promise((resolve) => {
      this.zone.runOutsideAngular(() => {
        this.http
          .post<ErpErrorCaptureResult[]>(`${this.base()}/errors`, batch, {
            context: internalContext(),
            headers: this.jsonHeaders(),
          })
          .pipe(
            timeout(20000),
            catchError(() => of(null)),
          )
          .subscribe({
            next: (r) => resolve(r ?? null),
            error: () => resolve(null),
          });
      });
    });
  }

  /* ----------------------------------------------------------- persistence */

  private persistQueue(): void {
    if (!this.config.persistQueue || typeof localStorage === 'undefined') return;
    try {
      // Cap what we persist: localStorage is 5 MB and shared with the ERP's own
      // state.  Filling it would break the application we are trying to protect.
      const slice = this.queue.slice(-50);
      localStorage.setItem(this.config.storageKey, JSON.stringify(slice));
    } catch {
      // QuotaExceeded or private mode - drop the persistence, keep the memory queue.
    }
  }

  private restoreQueue(): void {
    if (!this.config.persistQueue || typeof localStorage === 'undefined') return;
    try {
      const raw = localStorage.getItem(this.config.storageKey);
      if (!raw) return;
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        this.queue = parsed.slice(0, this.config.maxQueueSize);
      }
      localStorage.removeItem(this.config.storageKey);
    } catch {
      try {
        localStorage.removeItem(this.config.storageKey);
      } catch {
        /* nothing further to try */
      }
    }
  }

  /**
   * Last-gasp delivery on tab close.  sendBeacon survives the unload that would
   * cancel an XHR, which is the difference between capturing the error that
   * crashed the page and losing it.
   */
  private installUnloadFlush(): void {
    if (typeof window === 'undefined') return;

    const beacon = () => {
      if (!this.queue.length) return;
      try {
        if (typeof navigator !== 'undefined' && typeof navigator.sendBeacon === 'function') {
          const blob = new Blob([JSON.stringify(this.queue)], { type: 'application/json' });
          const ok = navigator.sendBeacon(`${this.base()}/errors/beacon`, blob);
          if (ok) {
            this.queue = [];
            this.persistQueue();
            return;
          }
        }
      } catch {
        /* fall through to persistence */
      }
      // Beacon unavailable or refused: leave it in localStorage for next load.
      this.persistQueue();
    };

    this.zone.runOutsideAngular(() => {
      // 'pagehide' fires on mobile Safari where 'beforeunload' does not.
      window.addEventListener('pagehide', beacon);
      window.addEventListener('beforeunload', beacon);
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'hidden') beacon();
      });
    });
  }
}
