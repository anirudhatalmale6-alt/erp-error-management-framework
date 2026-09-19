import { HttpErrorResponse } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { ERP_ERROR_CONFIG } from '../config/erp-error-config';
import { ErpErrorContextService } from '../core/erp-error-context.service';
import {
  classify,
  extractInnerChain,
  extractParentErrorReference,
  extractStack,
  unwrap,
} from '../core/classifier';
import { computeFingerprint } from '../core/fingerprint';
import { safeEndpoint, scrubText } from '../core/redaction';
import {
  ERP_NO_USER,
  ErpErrorCaptureResult,
  ErpErrorCategory,
  ErpErrorEnvelope,
  ErpValidationErrorItem,
} from '../models/error-envelope';
import { ErpErrorTransportService } from '../transport/erp-error-transport.service';

/** Optional extra context a caller can attach to a manual report. */
export interface ErpReportOptions {
  category?: ErpErrorCategory;
  component?: string | null;
  actionName?: string | null;
  formName?: string | null;
  lovName?: string | null;
  validationErrors?: ErpValidationErrorItem[] | null;
  customData?: Record<string, unknown> | null;
  /** Suppress the user-facing notification for this one report. */
  silent?: boolean;
  /** Extra HTTP context when the caller already has the failed response. */
  httpError?: HttpErrorResponse;
  requestPayload?: unknown;
  responsePayload?: unknown;
  durationMs?: number | null;
}

/**
 * Builds an envelope from an arbitrary thrown value and hands it to the
 * transport.  This is the single funnel that the ErrorHandler, the HTTP
 * interceptor, the form helper and any manual `report()` call all pass through,
 * so classification, redaction and fingerprinting happen exactly once and in
 * exactly one place.
 */
@Injectable({ providedIn: 'root' })
export class ErpErrorReporterService {
  private readonly config = inject(ERP_ERROR_CONFIG);
  private readonly context = inject(ErpErrorContextService);
  private readonly transport = inject(ErpErrorTransportService);

  private readonly headerAllow = new Set(this.config.headerAllowList.map((h) => h.toLowerCase()));

  /** Guards against an error raised inside the reporter re-entering it. */
  private reporting = false;

  async report(error: unknown, options: ErpReportOptions = {}): Promise<ErpErrorCaptureResult | null> {
    if (this.reporting) return null;

    try {
      this.reporting = true;
      const envelope = this.buildEnvelope(error, options);
      if (!envelope) return null;

      if (this.config.logToConsole) {
        // eslint-disable-next-line no-console
        console.warn('[erp-error-management] captured', envelope);
      }

      return await this.transport.enqueue(envelope);
    } catch {
      // Absolutely nothing in the reporter is allowed to propagate.
      return null;
    } finally {
      this.reporting = false;
    }
  }

  /** Exposed so the interceptor can decide before doing any work. */
  shouldIgnore(error: unknown, url?: string | null): boolean {
    try {
      if (url && this.config.ignoreUrlPatterns.some((p) => matches(p, url))) return true;

      const http = error instanceof HttpErrorResponse ? error : options_httpError(error);
      if (http) {
        if (this.config.ignoreHttpStatusCodes.includes(http.status)) return true;
        if (http.url && this.config.ignoreUrlPatterns.some((p) => matches(p, http.url!))) return true;
      }

      const message = messageOf(error);
      if (message && this.config.ignoreMessagePatterns.some((p) => matches(p, message))) return true;

      return false;
    } catch {
      return false;
    }
  }

  buildEnvelope(error: unknown, options: ErpReportOptions = {}): ErpErrorEnvelope | null {
    const raw = unwrap(error);
    const http = options.httpError ?? (raw instanceof HttpErrorResponse ? raw : undefined);

    if (this.shouldIgnore(raw, http?.url)) return null;

    const classification = classify({ error: raw, httpError: http, hint: options.category });

    const now = new Date();
    const stack = scrubText(extractStack(raw), 20000);
    const endpoint = http?.url ? safeEndpoint(http.url) : null;

    // Validation values are never sent - only the control path and the rule
    // that failed.  A 'required' failure on `nationalId` tells support
    // everything they need; the value would tell them something they must not
    // have.
    const validationKeys = options.validationErrors?.map((v) => `${v.control}:${v.rule}`) ?? null;

    const fingerprint = computeFingerprint({
      layer: classification.layer,
      category: classification.category,
      exceptionType: classification.exceptionType,
      message: classification.message,
      stackTrace: stack,
      component: options.component ?? this.context.activeComponent,
      screen: this.context.getScreen(),
      erpModule: this.context.getModule(),
      apiEndpoint: endpoint,
      httpStatusCode: http?.status ?? null,
      formName: options.formName ?? null,
      lovName: options.lovName ?? null,
      validationKeys,
    });

    const user = this.context.getUser();

    const envelope: ErpErrorEnvelope = {
      fingerprintHash: fingerprint.hash,
      signatureText: fingerprint.signature,

      layer: classification.layer,
      category: classification.category,
      severity: classification.severity,

      exceptionType: classification.exceptionType,
      message: scrubText(classification.message, 2000),
      normalizedMessage: fingerprint.normalizedMessage.slice(0, 2000),

      occurredUtc: now.toISOString(),
      occurredLocal: localIso(now),
      clientUtcOffsetMinutes: -now.getTimezoneOffset(),

      erpModule: this.context.getModule(),
      screen: this.context.getScreen(),
      routeUrl: this.context.getRouteUrl(),
      component: options.component ?? this.context.activeComponent,
      actionName: options.actionName ?? null,
      formName: options.formName ?? null,
      lovName: options.lovName ?? null,

      apiEndpoint: endpoint,
      httpMethod: null,
      httpStatusCode: http?.status ?? null,
      durationMs: options.durationMs ?? null,

      // Always present, and profileId is always a number. getUser() never
      // returns null now, so an error from a public page carries -1 rather than
      // an absent user object that the server then has to guess about.
      user: {
        profileId: user?.profileId ?? ERP_NO_USER,
        name: user?.name ?? null,
        displayName: user?.displayName ?? null,
        tenantId: user?.tenantId ?? null,
        sessionId: user?.sessionId ?? null,
      },
      client: this.context.getClientInfo(),

      correlationId: this.context.getCorrelationId(),
      requestId: null,
      // Links this browser-side symptom to the API-side row that recorded its
      // cause, so the correlation trail shows one incident rather than two
      // unrelated errors that happened to share a timestamp.
      parentErrorReference: extractParentErrorReference(raw),

      environment: this.config.environment,
      appVersion: this.config.appVersion ?? null,

      stackTrace: stack,
      innerExceptionChain: scrubText(extractInnerChain(raw), 4000),

      requestPayload: options.requestPayload ?? null,
      responsePayload: options.responsePayload ?? null,
      validationErrors: options.validationErrors ?? null,
      breadcrumbs: this.context.getBreadcrumbs(),
      customData: options.customData ?? null,
    };

    if (this.config.beforeSend) {
      try {
        return this.config.beforeSend(envelope);
      } catch {
        // A broken beforeSend hook must not silence the error.
        return envelope;
      }
    }

    return envelope;
  }

  headerAllowList(): ReadonlySet<string> {
    return this.headerAllow;
  }
}

function matches(pattern: string | RegExp, value: string): boolean {
  return typeof pattern === 'string' ? value.includes(pattern) : pattern.test(value);
}

function messageOf(error: unknown): string | null {
  if (typeof error === 'string') return error;
  const anyErr = error as Record<string, unknown> | null;
  return anyErr && typeof anyErr['message'] === 'string' ? (anyErr['message'] as string) : null;
}

function options_httpError(error: unknown): HttpErrorResponse | undefined {
  return error instanceof HttpErrorResponse ? error : undefined;
}

/** Local wall clock as an ISO-like string with no offset suffix. */
function localIso(d: Date): string {
  const p = (n: number, w = 2) => String(n).padStart(w, '0');
  return (
    `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}` +
    `T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`
  );
}
