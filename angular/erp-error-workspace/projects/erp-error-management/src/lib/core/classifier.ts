import { HttpErrorResponse } from '@angular/common/http';
import { ErpErrorCategory, ErpErrorLayer, ErpErrorSeverity } from '../models/error-envelope';

/**
 * Works out WHICH LAYER an error came from and how bad it is, from the error
 * object alone - the brief's "identify the application layer where the error
 * occurred" without asking any page to declare it.
 *
 * The important subtlety: an HttpErrorResponse caught in Angular is a SYMPTOM.
 * Its cause is a .NET exception or a SQL error that the API already captured
 * under the same correlation id.  So a 500 is classified as layer 'http', not
 * 'database', even when the body mentions a deadlock - the database-layer row
 * is written by the API-side capture, and the two are joined by correlation id.
 * Classifying the symptom as the cause is how you end up with two fingerprints
 * for one fault and a ticket count that double-counts.
 */

export interface ClassificationInput {
  error: unknown;
  /** Set when the error arrived through the HTTP interceptor. */
  httpError?: HttpErrorResponse;
  /** Set by the caller for form/LOV/submit helpers. */
  hint?: ErpErrorCategory;
}

export interface Classification {
  layer: ErpErrorLayer;
  category: ErpErrorCategory;
  severity: ErpErrorSeverity;
  exceptionType: string;
  message: string;
}

const CHUNK_LOAD_PATTERNS = [
  /Loading chunk \d+ failed/i,
  /ChunkLoadError/i,
  /Failed to fetch dynamically imported module/i,
  /Importing a module script failed/i,
];

export function classify(input: ClassificationInput): Classification {
  const raw = unwrap(input.error);
  const message = extractMessage(raw);
  const exceptionType = extractType(raw);

  const http = input.httpError ?? (raw instanceof HttpErrorResponse ? raw : undefined);

  if (http) {
    return classifyHttp(http, exceptionType, message);
  }

  if (input.hint) {
    return {
      layer: 'angular',
      category: input.hint,
      severity: severityForCategory(input.hint),
      exceptionType,
      message,
    };
  }

  // A failed lazy-route chunk is nearly always a stale index.html against a new
  // deployment.  Worth its own category: the fix is a reload, not a code change.
  if (CHUNK_LOAD_PATTERNS.some((p) => p.test(message) || p.test(exceptionType))) {
    return { layer: 'angular', category: 'chunk_load', severity: 'high', exceptionType, message };
  }

  // Angular template/expression failures carry an NG#### code.
  if (/\bNG0\d{3}\b/.test(message)) {
    return { layer: 'angular', category: 'angular_render', severity: 'high', exceptionType, message };
  }

  if (typeof navigator !== 'undefined' && navigator.onLine === false) {
    return { layer: 'angular', category: 'client_network', severity: 'medium', exceptionType, message };
  }

  return { layer: 'angular', category: 'angular_runtime', severity: 'high', exceptionType, message };
}

function classifyHttp(
  http: HttpErrorResponse,
  exceptionType: string,
  message: string,
): Classification {
  const status = http.status;

  // status 0 means the request never reached the server: DNS, CORS, offline,
  // certificate, or the user navigated away mid-flight.
  if (status === 0) {
    const offline = typeof navigator !== 'undefined' && navigator.onLine === false;
    return {
      layer: 'angular',
      category: offline ? 'client_network' : 'client_network',
      severity: offline ? 'low' : 'high',
      exceptionType: 'HttpErrorResponse',
      message: offline ? 'The browser is offline.' : message,
    };
  }

  if (status === 401 || status === 403) {
    return { layer: 'http', category: 'auth', severity: 'medium', exceptionType, message };
  }
  if (status === 408 || status === 504) {
    return { layer: 'http', category: 'http_timeout', severity: 'high', exceptionType, message };
  }
  if (status >= 500) {
    return { layer: 'http', category: 'http_server', severity: 'critical', exceptionType, message };
  }
  if (status >= 400) {
    return { layer: 'http', category: 'http_client', severity: 'medium', exceptionType, message };
  }

  return { layer: 'http', category: 'unclassified', severity: 'medium', exceptionType, message };
}

function severityForCategory(category: ErpErrorCategory): ErpErrorSeverity {
  switch (category) {
    case 'validation':
      return 'low';
    case 'lov_lookup':
    case 'submit_action':
      return 'medium';
    case 'chunk_load':
    case 'angular_render':
    case 'angular_runtime':
      return 'high';
    default:
      return 'medium';
  }
}

/**
 * Angular wraps thrown values in several ways depending on where they were
 * raised (zone, rxjs, promise, ErrorHandler).  Peel until we hit something
 * that actually carries a message and a stack.
 */
export function unwrap(error: unknown, depth = 0): unknown {
  if (depth > 5 || error === null || error === undefined) return error;

  const anyErr = error as Record<string, unknown>;

  // Zone.js and Angular both use `rejection` for an unhandled promise.
  if (anyErr['rejection'] !== undefined) return unwrap(anyErr['rejection'], depth + 1);
  // Angular's ErrorHandler wraps the original in `ngOriginalError`.
  if (anyErr['ngOriginalError'] !== undefined) return unwrap(anyErr['ngOriginalError'], depth + 1);
  // Native ErrorEvent from window.onerror.
  if (typeof ErrorEvent !== 'undefined' && error instanceof ErrorEvent && error.error) {
    return unwrap(error.error, depth + 1);
  }
  // HttpErrorResponse.error can itself be an ErrorEvent (network-level failure).
  if (error instanceof HttpErrorResponse && error.error instanceof ErrorEvent) {
    return error;
  }

  return error;
}

export function extractMessage(error: unknown): string {
  if (error === null || error === undefined) return 'Unknown error (null)';
  if (typeof error === 'string') return error;

  if (error instanceof HttpErrorResponse) {
    const body = error.error as Record<string, unknown> | string | null;
    const generic = `${error.status} ${error.statusText || 'HTTP error'} on ${stripQuery(error.url)}`;

    // If the body carries an errorReference, the API has ALREADY captured this
    // fault with its real cause (the .NET exception, the SQL error).  Its
    // `message` is then the deliberately non-technical text meant for the user -
    // recording that as the browser-side message would fill the error store
    // with 4,000 identical rows reading "an unexpected problem occurred", all
    // fingerprinting to the same useless signature.  Use the status and
    // endpoint instead; the cause is one join away via the correlation id.
    if (body && typeof body === 'object' && 'errorReference' in body) return generic;

    if (typeof body === 'string' && body.trim()) return body.slice(0, 2000);
    if (body && typeof body === 'object') {
      const detail =
        (body['detail'] as string) ??
        (body['title'] as string) ??
        (body['Message'] as string) ??
        (body['message'] as string) ??
        (body['ExceptionMessage'] as string);
      if (detail) return String(detail).slice(0, 2000);
    }
    return generic;
  }

  if (error instanceof Error) return error.message || error.name || 'Error';

  const anyErr = error as Record<string, unknown>;
  if (typeof anyErr['message'] === 'string') return anyErr['message'] as string;

  try {
    return JSON.stringify(error).slice(0, 2000);
  } catch {
    return Object.prototype.toString.call(error);
  }
}

/** The reference the API already assigned to this same fault, if it sent one. */
export function extractParentErrorReference(error: unknown): string | null {
  if (!(error instanceof HttpErrorResponse)) return null;
  try {
    const fromHeader = error.headers?.get('X-Error-Reference');
    if (fromHeader) return fromHeader;
    const body = error.error as Record<string, unknown> | null;
    const fromBody = body && typeof body === 'object' ? body['errorReference'] : null;
    return typeof fromBody === 'string' && fromBody ? fromBody : null;
  } catch {
    return null;
  }
}

function stripQuery(url: string | null | undefined): string {
  if (!url) return '(unknown url)';
  const q = url.indexOf('?');
  const path = q < 0 ? url : url.slice(0, q);
  try {
    return new URL(path).pathname;
  } catch {
    return path;
  }
}

export function extractType(error: unknown): string {
  if (error === null || error === undefined) return 'Unknown';
  if (error instanceof HttpErrorResponse) return 'HttpErrorResponse';
  if (error instanceof Error) return error.name || error.constructor?.name || 'Error';
  if (typeof error === 'string') return 'String';
  return (error as object).constructor?.name ?? typeof error;
}

export function extractStack(error: unknown): string | null {
  if (error instanceof Error && typeof error.stack === 'string') return error.stack;
  const anyErr = error as Record<string, unknown> | null;
  if (anyErr && typeof anyErr['stack'] === 'string') return anyErr['stack'] as string;
  return null;
}

/** Flatten `cause` / `innerException` chains into one readable block. */
export function extractInnerChain(error: unknown): string | null {
  const parts: string[] = [];
  let current: unknown = error;
  let depth = 0;

  while (current && depth < 8) {
    const anyErr = current as Record<string, unknown>;
    const next = anyErr['cause'] ?? anyErr['innerException'] ?? anyErr['InnerException'];
    if (!next) break;
    parts.push(`${extractType(next)}: ${extractMessage(next)}`);
    current = next;
    depth++;
  }

  return parts.length ? parts.join('\n --> ') : null;
}
