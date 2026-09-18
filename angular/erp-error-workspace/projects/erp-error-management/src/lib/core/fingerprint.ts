import { sha256Hex } from './sha256';
import { ErpErrorCategory, ErpErrorLayer } from '../models/error-envelope';

/**
 * Deduplication.
 *
 * The problem the brief describes - "repeated occurrences of the same or
 * substantially similar error should be grouped without creating duplicate
 * tickets" - is entirely a question of what counts as "the same".  Get it too
 * loose and two unrelated faults share one ticket; too tight and one broken LOV
 * opens 4,000 tickets because each carries a different record id in its message.
 *
 * The approach here: build a SIGNATURE from only the stable parts of an error,
 * hash it, and treat the hash as the identity of the problem.
 *
 * Stable:    layer, category, exception type, the SHAPE of the message,
 *            the top few stack frames by function name, and the location
 *            (component / endpoint / SQL object) appropriate to the layer.
 * Volatile:  ids, GUIDs, dates, quoted literals, numbers, file paths, line and
 *            column numbers, minified bundle hashes, user names, timestamps.
 *
 * The signature text is stored next to the hash in ERM.ERM_ErrorFingerprint, so
 * an administrator can always see WHY two errors were grouped - a hash nobody
 * can explain is a hash nobody will trust.
 *
 * The identical algorithm exists in C# (Erp.ErrorManagement.Core/Fingerprint.cs)
 * so an Angular-reported and a .NET-reported instance of the same fault land on
 * the same row.
 */

const RX_GUID = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
const RX_ISO_DATE = /\b\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?\b/g;
const RX_QUOTED_SINGLE = /'[^']*'/g;
const RX_QUOTED_DOUBLE = /"[^"]*"/g;
const RX_HEX = /\b0x[0-9a-f]+\b/gi;
const RX_LONG_HEX = /\b[0-9a-f]{16,}\b/gi;
const RX_NUMBER = /\b\d+(\.\d+)?\b/g;
const RX_URL = /\bhttps?:\/\/[^\s)'"]+/gi;
const RX_WINDOWS_PATH = /\b[a-z]:\\[^\s:)'"]+/gi;
const RX_EMAIL = /\b[^\s@]+@[^\s@]+\.[^\s@]+\b/g;
const RX_WS = /\s+/g;

/**
 * Reduce a message to its shape.  Order matters: URLs and paths are replaced
 * before numbers, otherwise the port and the path segments become {n}{n}{n} and
 * two different endpoints collapse into one.
 */
export function normalizeMessage(message: string | null | undefined): string {
  if (!message) return '';
  return message
    .replace(RX_URL, '{url}')
    .replace(RX_WINDOWS_PATH, '{path}')
    .replace(RX_EMAIL, '{email}')
    .replace(RX_GUID, '{guid}')
    .replace(RX_ISO_DATE, '{date}')
    .replace(RX_QUOTED_SINGLE, "'{str}'")
    .replace(RX_QUOTED_DOUBLE, '"{str}"')
    .replace(RX_HEX, '{hex}')
    .replace(RX_LONG_HEX, '{hex}')
    .replace(RX_NUMBER, '{n}')
    .replace(RX_WS, ' ')
    .trim()
    .slice(0, 500);
}

/**
 * Keep the call path, drop everything about WHERE the file lived.
 *
 * A production Angular bundle changes its chunk hash on every deploy, and the
 * line numbers move with any edit above the fault.  Including either of those
 * means the same bug fingerprints differently after every release, the
 * occurrence count resets to 1, and the recurring-problem report - the thing
 * that makes a permanent fix worth doing - never fires.
 */
export function normalizeStackFrames(stack: string | null | undefined, depth = 5): string[] {
  if (!stack) return [];
  const frames: string[] = [];

  for (const rawLine of stack.split('\n')) {
    const line = rawLine.trim();
    if (!line || line === 'Error' || /^[A-Za-z.]*(Error|Exception):/.test(line)) continue;

    let frame = line
      // Chrome/Edge: "at ClassName.method (http://host/main-ABC123.js:1:2345)"
      .replace(/^at\s+/i, '')
      // Firefox/Safari: "method@http://host/main.js:1:2345"
      .replace(/@.*$/, '')
      // Strip the parenthesised location entirely.
      .replace(/\s*\(.*\)\s*$/, '')
      // Any surviving bare location.
      .replace(/https?:\/\/\S+/g, '')
      .replace(/:\d+:\d+$/, '')
      .trim();

    // Webpack/Vite name-mangled anonymous frames carry no information.
    if (!frame || frame === '<anonymous>' || frame === 'Object.<anonymous>') continue;
    // Framework frames are the same for every fault; they dilute the signature.
    if (/^(zone|Zone|ZoneDelegate|ZoneTask|invokeTask|runTask|drainMicroTaskQueue)\b/.test(frame)) continue;

    frames.push(frame);
    if (frames.length >= depth) break;
  }

  return frames;
}

export interface FingerprintInput {
  layer: ErpErrorLayer;
  category: ErpErrorCategory;
  exceptionType?: string | null;
  message?: string | null;
  stackTrace?: string | null;
  /** Angular layer. */
  component?: string | null;
  screen?: string | null;
  erpModule?: string | null;
  /** HTTP / API layers. */
  apiController?: string | null;
  apiAction?: string | null;
  apiEndpoint?: string | null;
  httpStatusCode?: number | null;
  /** Database layer. */
  sqlErrorNumber?: number | null;
  sqlObjectName?: string | null;
  /** Form / LOV layers. */
  formName?: string | null;
  lovName?: string | null;
  /** Validation errors contribute their control+rule pairs, never their values. */
  validationKeys?: string[] | null;
  stackFrameDepth?: number;
}

export interface FingerprintResult {
  hash: string;
  signature: string;
  normalizedMessage: string;
}

/**
 * Which location fields belong in the signature depends on the layer.  A SQL
 * deadlock in usp_PostJournal is the same problem whichever screen triggered
 * it; an Angular template error in InvoiceLineComponent is not the same problem
 * as one in CustomerSearchComponent even if the message is identical.
 */
function locationParts(i: FingerprintInput): string[] {
  switch (i.layer) {
    case 'angular':
      return [i.erpModule ?? '', i.component ?? i.screen ?? '', i.formName ?? '', i.lovName ?? ''];
    case 'http':
      // Endpoint without its query string or embedded ids - those are volatile.
      return [normalizeEndpoint(i.apiEndpoint), String(i.httpStatusCode ?? '')];
    case 'webapi':
    case 'business':
    case 'data':
      return [i.apiController ?? '', i.apiAction ?? ''];
    case 'database':
      return [String(i.sqlErrorNumber ?? ''), i.sqlObjectName ?? ''];
    default:
      return [i.erpModule ?? '', i.screen ?? ''];
  }
}

/** '/api/invoices/4821/lines?page=2' -> '/api/invoices/{id}/lines' */
export function normalizeEndpoint(endpoint: string | null | undefined): string {
  if (!endpoint) return '';
  return endpoint
    .split('?')[0]
    .replace(RX_GUID, '{id}')
    .replace(/\/\d+(?=\/|$)/g, '/{id}')
    .replace(/\/+$/, '')
    .toLowerCase();
}

export function computeFingerprint(input: FingerprintInput): FingerprintResult {
  const normalizedMessage = normalizeMessage(input.message);
  const frames = normalizeStackFrames(input.stackTrace, input.stackFrameDepth ?? 5);

  const parts = [
    input.layer,
    input.category,
    (input.exceptionType ?? '').trim(),
    normalizedMessage,
    ...locationParts(input),
    ...(input.validationKeys ?? []).slice().sort(),
    ...frames,
  ];

  // '|' is the separator; strip it from the parts so a value containing a pipe
  // cannot be crafted to collide with a different part layout.
  const signature = parts.map((p) => String(p ?? '').replace(/\|/g, '/')).join('|');

  return { hash: sha256Hex(signature), signature: signature.slice(0, 1000), normalizedMessage };
}
