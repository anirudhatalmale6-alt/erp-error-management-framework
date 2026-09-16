import { inject } from '@angular/core';
import { MonoTypeOperatorFunction, Observable, OperatorFunction } from 'rxjs';
import { tap } from 'rxjs/operators';
import { ErpErrorCategory } from '../models/error-envelope';
import { ErpErrorReporterService, ErpReportOptions } from './erp-error-reporter.service';

/**
 * HANDLED FAILURES — the failures that never throw.
 *
 * A global ErrorHandler can only see what propagates. It cannot see:
 *
 *   try { … } catch (e) { this.toast('Could not save'); return null; }
 *   const result = await this.api.post(…);  if (!result.ok) { return; }
 *   if (!rows.length) { this.message = 'No cost centres found'; return; }
 *
 * These are the most common real-world ERP failures and the ones users actually
 * complain about, precisely because they were "handled" — handled meaning
 * shown to one user and then forgotten, with nothing recorded anywhere.
 *
 * There is no way to capture a value-returning failure without SOME signal at
 * the point that decides it is a failure; that decision only exists in the
 * calling code. What this file does is make that signal as close to free as
 * possible — one pipe operator, or one line in an existing catch block — so
 * adopting it is an edit, never a rewrite.
 *
 * Everything here funnels into the same reporter as the automatic paths, so a
 * handled failure is fingerprinted, deduplicated, redacted and reported exactly
 * like an uncaught one.
 */

/* ========================================================================== */
/*  rxjs operators                                                            */
/* ========================================================================== */

/**
 * Report when a stream's emitted value is a failure, judged by a predicate.
 *
 * For the extremely common "API returns 200 with `{ success: false }`" shape,
 * which no HTTP interceptor can detect — the transport succeeded, only the
 * operation failed:
 *
 *   this.http.post<SaveResult>(url, dto).pipe(
 *     erpReportIf(r => !r.success, r => `Save refused: ${r.reasonCode}`,
 *                 { category: 'submit_action', actionName: 'savePurchaseOrder' }),
 *   ).subscribe(…);
 *
 * The stream is NOT altered: the value passes through untouched and the
 * subscriber behaves exactly as before. Pure observation.
 */
export function erpReportIf<T>(
  isFailure: (value: T) => boolean,
  describe: (value: T) => string,
  options?: ErpReportOptions,
): MonoTypeOperatorFunction<T> {
  const reporter = inject(ErpErrorReporterService);

  return (source: Observable<T>) =>
    source.pipe(
      tap((value) => {
        try {
          if (!isFailure(value)) return;
          void reporter.report(new Error(describe(value)), {
            category: options?.category ?? 'submit_action',
            silent: options?.silent ?? true,
            ...options,
          });
        } catch {
          // A throwing predicate or describe() must not break the stream it
          // was only supposed to be watching.
        }
      }),
    );
}

/**
 * Report when a lookup / LOV stream comes back empty.
 *
 * An empty LOV is not obviously an error, which is exactly why it goes
 * unreported for months. In an ERP it usually means a data or permission
 * problem: the user cannot proceed and nobody finds out.
 *
 *   this.http.get<CostCentre[]>(url).pipe(erpReportIfEmpty('COST_CENTRE'))
 */
export function erpReportIfEmpty<T extends { length: number }>(
  lovName: string,
  options?: ErpReportOptions,
): MonoTypeOperatorFunction<T> {
  const reporter = inject(ErpErrorReporterService);

  return (source: Observable<T>) =>
    source.pipe(
      tap((value) => {
        try {
          if (value && value.length > 0) return;
          void reporter.report(new Error(`Lookup "${lovName}" returned no rows`), {
            category: 'lov_lookup',
            lovName,
            silent: true,
            customData: { resolvedCount: 0 },
            ...options,
          });
        } catch {
          /* observation only */
        }
      }),
    );
}

/**
 * Report a failure the caller has already decided about, from inside a `catch`,
 * a `.catch()`, or an error callback — without rethrowing.
 *
 * Use when existing code must keep its current behaviour exactly (show a toast,
 * return a default) but the failure should stop being invisible:
 *
 *   catch (e) {
 *     this.reportHandled(e, { actionName: 'recalculateTotals' });   // added
 *     this.toast('Could not recalculate');                          // unchanged
 *     return previousTotals;                                        // unchanged
 *   }
 *
 * One added line. Nothing existing is restructured, and control flow is
 * untouched — which is the whole constraint.
 */
export function erpReportHandled(
  reporter: ErpErrorReporterService,
  error: unknown,
  options?: ErpReportOptions,
): void {
  try {
    void reporter.report(error, {
      category: options?.category ?? 'submit_action',
      // Handled failures default to SILENT: the calling code has already told
      // the user something. A second dialog on top of its own toast would be
      // the framework making the user experience worse, not better.
      silent: options?.silent ?? true,
      customData: { handled: true, ...(options?.customData ?? {}) },
      ...options,
    });
  } catch {
    /* reporting a handled failure must never create an unhandled one */
  }
}

/**
 * Wrap a promise-returning function so a rejection is reported and then
 * re-thrown unchanged. For `async` service methods whose callers already
 * handle rejection:
 *
 *   await erpObserveAsync(() => this.api.postJournal(dto),
 *                         reporter, { actionName: 'postJournal' });
 */
export async function erpObserveAsync<T>(
  work: () => Promise<T>,
  reporter: ErpErrorReporterService,
  options?: ErpReportOptions,
): Promise<T> {
  try {
    return await work();
  } catch (error) {
    // Reported, then re-thrown untouched. The framework observes; it does not
    // swallow, and it does not change what the caller sees.
    erpReportHandled(reporter, error, { silent: false, ...options });
    throw error;
  }
}

/* ========================================================================== */
/*  Result-type bridge                                                        */
/* ========================================================================== */

/**
 * The shape most in-house ERP service layers converge on independently. Only
 * the failure discriminator is needed, so this is intentionally loose - it is
 * a structural match, not a base class to inherit.
 */
export interface ErpOperationResultLike {
  success?: boolean;
  ok?: boolean;
  isSuccess?: boolean;
  failed?: boolean;
  errorCode?: string | number | null;
  reasonCode?: string | number | null;
  message?: string | null;
  errors?: unknown;
}

/**
 * Best-effort "is this a failure result?" for the conventions listed above.
 *
 * Deliberately conservative: an object carrying NONE of the known
 * discriminators is treated as a SUCCESS. Guessing the other way would report
 * every successful response in the application as a failure, which is the
 * fastest possible way to make an error console worthless.
 */
export function isErpFailureResult(value: unknown): boolean {
  if (value === null || value === undefined) return false;
  if (typeof value !== 'object') return false;

  const v = value as ErpOperationResultLike;

  if (typeof v.success === 'boolean') return !v.success;
  if (typeof v.ok === 'boolean') return !v.ok;
  if (typeof v.isSuccess === 'boolean') return !v.isSuccess;
  if (typeof v.failed === 'boolean') return v.failed;

  // A populated error code with no boolean flag anywhere is still a failure.
  if (v.errorCode !== null && v.errorCode !== undefined && v.errorCode !== '' && v.errorCode !== 0) {
    return true;
  }

  return false;
}

/** Human-readable description of a failure result, for the error message. */
export function describeErpFailureResult(value: unknown, fallback = 'Operation failed'): string {
  const v = (value ?? {}) as ErpOperationResultLike;
  const code = v.errorCode ?? v.reasonCode;
  const message = typeof v.message === 'string' && v.message.trim() ? v.message.trim() : null;

  if (code && message) return `${fallback} [${code}]: ${message}`;
  if (code) return `${fallback} [${code}]`;
  if (message) return `${fallback}: ${message}`;
  return fallback;
}

/**
 * The zero-configuration form of `erpReportIf` for the result convention.
 *
 *   this.http.post<SaveResult>(url, dto).pipe(
 *     erpReportFailedResult({ actionName: 'savePurchaseOrder' }),
 *   )
 *
 * If a shared API wrapper already exists in the ERP - most in-house codebases
 * have one - adding this operator there covers every call in the system at
 * once. That is the single highest-leverage line available for this category.
 */
export function erpReportFailedResult<T>(
  options?: ErpReportOptions & { describe?: (value: T) => string },
): MonoTypeOperatorFunction<T> {
  const describe =
    options?.describe ?? ((value: T) => describeErpFailureResult(value, 'Operation returned a failure result'));
  return erpReportIf<T>(isErpFailureResult, describe, options);
}

/**
 * Report a business-rule refusal the ERP decided about itself - a credit-limit
 * block, a period-closed refusal, an approval-authority failure.
 *
 * Severity `low`, never shown to the user: the screen has already explained it.
 * These are captured so "which rule blocks our users most often, on which
 * screen" is a query rather than an opinion.
 */
export function erpReportBusinessRule(
  reporter: ErpErrorReporterService,
  ruleName: string,
  detail?: { code?: string | number | null; message?: string | null; actionName?: string | null },
): void {
  try {
    void reporter.report(
      new Error(`Business rule "${ruleName}" refused the operation` + (detail?.message ? `: ${detail.message}` : '')),
      {
        category: 'business_rule' as ErpErrorCategory,
        actionName: detail?.actionName ?? null,
        silent: true,
        customData: { ruleName, code: detail?.code ?? null },
      },
    );
  } catch {
    /* observation only */
  }
}

/**
 * `erpReportIf` for a stream whose failure is signalled by an ERROR rather than
 * a value, where the caller supplies its own recovery and must not rethrow.
 *
 * Reports, then delegates to the caller's recovery, so the stream still
 * completes normally:
 *
 *   .pipe(erpCatchAndRecover(() => of([]), { lovName: 'COST_CENTRE' }))
 */
export function erpCatchAndRecover<T, R>(
  recover: (error: unknown) => Observable<R>,
  options?: ErpReportOptions,
): OperatorFunction<T, T | R> {
  const reporter = inject(ErpErrorReporterService);

  return (source: Observable<T>) =>
    new Observable<T | R>((subscriber) => {
      const sub = source.subscribe({
        next: (v) => subscriber.next(v),
        complete: () => subscriber.complete(),
        error: (error: unknown) => {
          erpReportHandled(reporter, error, options);
          try {
            recover(error).subscribe({
              next: (v) => subscriber.next(v),
              complete: () => subscriber.complete(),
              error: (e) => subscriber.error(e),
            });
          } catch (e) {
            subscriber.error(e);
          }
        },
      });
      return () => sub.unsubscribe();
    });
}
