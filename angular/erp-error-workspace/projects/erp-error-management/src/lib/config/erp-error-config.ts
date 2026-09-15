import { InjectionToken } from '@angular/core';
import { ErpErrorEnvelope, ErpErrorSeverity } from '../models/error-envelope';

/**
 * Everything the host application can tune at bootstrap.  Runtime-tunable
 * behaviour (sampling, what to store, mute windows) lives in the database
 * instead - see erp_err.Setting - so it can change without a redeploy.
 */
export interface ErpErrorConfig {
  /** Base URL of the error-management API, e.g. '/api/error-management'. */
  apiBaseUrl: string;

  /** 'Production' | 'UAT' | 'Development' ... free text, stored as-is. */
  environment: string;

  /** Version stamped on every envelope.  Usually your build number. */
  appVersion?: string;

  /**
   * Name of the ERP module the application (or lazy-loaded feature) belongs to.
   * Can be overridden per route - see ERP_ERROR_ROUTE_CONTEXT.
   */
  defaultErpModule?: string;

  /** URL patterns that must never be intercepted (the capture endpoint itself, auth refresh, health checks). */
  ignoreUrlPatterns: (string | RegExp)[];

  /** Messages matching any of these are dropped before they reach the network. */
  ignoreMessagePatterns: (string | RegExp)[];

  /** HTTP status codes that are the application's business, not an incident. */
  ignoreHttpStatusCodes: number[];

  /** Show the blocking modal, or a non-blocking toast, or nothing. */
  notificationMode: 'dialog' | 'toast' | 'silent';

  /** Severities that trigger a user-visible notification at all. */
  notifyOnSeverities: ErpErrorSeverity[];

  /** Max envelopes held in the offline/retry buffer before the oldest are dropped. */
  maxQueueSize: number;

  /** Max envelopes sent in one POST. */
  batchSize: number;

  /** How long to wait before flushing a partial batch. */
  flushIntervalMs: number;

  /** Backoff schedule, in ms, for a failed flush.  The last value repeats. */
  retryDelaysMs: number[];

  /** Size of the breadcrumb ring buffer. */
  maxBreadcrumbs: number;

  /** Attach the (redacted) request body of a failed HTTP call. */
  captureRequestBody: boolean;

  /** Attach the (redacted) response body of a failed HTTP call. */
  captureResponseBody: boolean;

  /** Header names whose values are safe to record.  Everything else becomes '***'. */
  headerAllowList: string[];

  /** Query-string / body keys whose values are safe to record. */
  payloadKeyAllowList: string[];

  /** Persist the queue across reloads so an error during a crash still arrives. */
  persistQueue: boolean;

  /** localStorage key for the persisted queue. */
  storageKey: string;

  /** Do not re-open the dialog for the same fingerprint within this many ms. */
  duplicateDialogSuppressionMs: number;

  /** Also log the captured envelope to the browser console. */
  logToConsole: boolean;

  /**
   * Last chance to change or drop an envelope before it is sent.
   * Return null to discard it entirely.
   */
  beforeSend?: (envelope: ErpErrorEnvelope) => ErpErrorEnvelope | null;

  /**
   * Resolve the signed-in user.  Left to the host application because every
   * ERP stores identity somewhere different (JWT claim, session service, NgRx
   * store).  Called lazily, inside a try/catch - if it throws, capture
   * continues with an anonymous user rather than losing the error.
   */
  userProvider?: () => {
    id?: string | null;
    name?: string | null;
    displayName?: string | null;
    tenantId?: string | null;
    sessionId?: string | null;
  } | null;
}

export const ERP_ERROR_CONFIG = new InjectionToken<ErpErrorConfig>('ERP_ERROR_CONFIG');

export const ERP_ERROR_DEFAULT_CONFIG: ErpErrorConfig = {
  apiBaseUrl: '/api/error-management',
  environment: 'Production',
  ignoreUrlPatterns: [
    /\/api\/error-management\//i,
    /\/health$/i,
    /\/token$/i,
    /\/refresh$/i,
    // Chrome/Edge probe these on every page load; a 404 here is not an incident.
    /\/favicon\.ico$/i,
    /\.well-known\//i,
  ],
  ignoreMessagePatterns: [
    // Raised by the browser when a request is cancelled by navigation.
    /ResizeObserver loop limit exceeded/i,
    /ResizeObserver loop completed with undelivered notifications/i,
    // Angular router cancels in-flight resolvers; not a fault.
    /NG04002/i,
    // Extensions inject these into the page; they are not our code.
    /^Script error\.?$/i,
    /chrome-extension:\/\//i,
    /moz-extension:\/\//i,
  ],
  ignoreHttpStatusCodes: [
    401, // handled by the auth interceptor - a redirect, not an incident
    409, // optimistic-concurrency conflicts are shown to the user by the screen
    422, // server-side validation the form already renders
  ],
  notificationMode: 'dialog',
  notifyOnSeverities: ['critical', 'high', 'medium'],
  maxQueueSize: 200,
  batchSize: 10,
  flushIntervalMs: 2000,
  retryDelaysMs: [1000, 5000, 15000, 60000],
  maxBreadcrumbs: 25,
  captureRequestBody: true,
  captureResponseBody: false,
  headerAllowList: [
    'content-type',
    'accept',
    'accept-language',
    'user-agent',
    'referer',
    'x-correlation-id',
    'x-request-id',
    'x-erp-module',
    'x-erp-screen',
    'x-app-version',
  ],
  payloadKeyAllowList: [
    'id',
    'code',
    'documentno',
    'status',
    'modulecode',
    'screencode',
    'action',
    'rowversion',
    'page',
    'pagesize',
    'sort',
    'sortdirection',
    'lovcode',
    'fromdate',
    'todate',
  ],
  persistQueue: true,
  storageKey: 'erp.error.queue.v1',
  duplicateDialogSuppressionMs: 20000,
  logToConsole: false,
};

/**
 * Per-route context.  Set `data: { erpErrorContext: { module: 'GL', screen: 'Journal Entry' } }`
 * on a route and every error raised under it is stamped automatically - no
 * per-component wiring, which is the whole point of the brief.
 */
export interface ErpErrorRouteContext {
  module?: string;
  screen?: string;
}
