/**
 * Sensitive-data handling.
 *
 * The rule here is an ALLOW-LIST, not a deny-list, and that is a deliberate
 * decision worth defending.
 *
 * A deny-list ("redact anything called password, token, secret, ssn...") is
 * wrong the moment somebody adds a field the list has never heard of -
 * `iqamaNumber`, `bankIban`, `otpCode`, `answerToSecurityQuestion`.  The list
 * does not fail loudly; it quietly writes the value into the error store, where
 * it is then read by every support user with console access and copied into
 * every ticket export.  You find out during an audit.
 *
 * An allow-list fails the other way: a field nobody has classified shows up as
 * '***' and someone asks for it to be added.  That is a support ticket, not a
 * breach.
 *
 * The allow-list itself lives in erp_err.RedactionAllowList so it can be
 * extended without a front-end release.
 */

export const REDACTED = '***';

/** Values matching these are masked even if their KEY is on the allow-list. */
const RX_JWT = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g;
const RX_BEARER = /\bBearer\s+[A-Za-z0-9._~+/=-]{16,}/gi;
const RX_BASIC = /\bBasic\s+[A-Za-z0-9+/=]{16,}/gi;
const RX_PAN = /\b(?:\d[ -]?){13,19}\b/g;
const RX_CONNSTR = /\b(password|pwd|user id|uid)\s*=\s*[^;]+/gi;

/**
 * Second line of defence: even an allow-listed field, and every free-text
 * message and stack trace, is swept for things that are obviously a credential
 * regardless of what they are called.  This is the one place a deny-list is
 * correct - not as the policy, but as a backstop under it.
 */
export function scrubText(value: string | null | undefined, maxLength = 4000): string | null {
  if (value === null || value === undefined) return null;
  let out = String(value)
    .replace(RX_JWT, REDACTED)
    .replace(RX_BEARER, 'Bearer ' + REDACTED)
    .replace(RX_BASIC, 'Basic ' + REDACTED)
    .replace(RX_CONNSTR, (_m, key) => `${key}=${REDACTED}`)
    .replace(RX_PAN, (m) => (luhn(m) ? REDACTED : m));

  if (out.length > maxLength) {
    out = out.slice(0, maxLength) + `... [truncated at ${maxLength} chars]`;
  }
  return out;
}

/**
 * Only mask a 13-19 digit run if it actually checksums as a card number.
 * Without this, every ERP document number, GL account and phone number in every
 * error message reads as '***' and the store becomes useless for diagnosis.
 */
function luhn(candidate: string): boolean {
  const digits = candidate.replace(/[^\d]/g, '');
  if (digits.length < 13 || digits.length > 19) return false;
  let sum = 0;
  let alt = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let n = digits.charCodeAt(i) - 48;
    if (alt) {
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
    alt = !alt;
  }
  return sum % 10 === 0;
}

/**
 * Walk an arbitrary object and keep only the values whose key is allow-listed.
 * Structure is preserved (so you can still see THAT a field was present and
 * what shape the payload had), values are not.
 */
export function redactObject(
  value: unknown,
  allowedKeys: ReadonlySet<string>,
  depth = 0,
  maxDepth = 6,
): unknown {
  if (value === null || value === undefined) return value;
  if (depth > maxDepth) return '[max depth]';

  if (Array.isArray(value)) {
    // Cap the array: an error on a 5,000-row grid save must not write 5,000
    // redacted objects into the error store.
    const capped = value.slice(0, 20).map((v) => redactObject(v, allowedKeys, depth + 1, maxDepth));
    if (value.length > 20) capped.push(`[+${value.length - 20} more items]`);
    return capped;
  }

  if (value instanceof Date) return value.toISOString();

  if (typeof value === 'object') {
    // FormData / File / Blob: record the shape, never the content.
    if (typeof FormData !== 'undefined' && value instanceof FormData) {
      const keys: string[] = [];
      value.forEach((_v, k) => keys.push(k));
      return { '[FormData]': keys };
    }
    if (typeof Blob !== 'undefined' && value instanceof Blob) {
      return { '[Blob]': { size: value.size, type: value.type } };
    }

    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (allowedKeys.has(k.toLowerCase())) {
        out[k] =
          typeof v === 'object' && v !== null
            ? redactObject(v, allowedKeys, depth + 1, maxDepth)
            : typeof v === 'string'
              ? scrubText(v, 500)
              : v;
      } else if (typeof v === 'object' && v !== null) {
        // Descend: a nested object may contain allow-listed keys worth keeping.
        out[k] = redactObject(v, allowedKeys, depth + 1, maxDepth);
      } else {
        out[k] = REDACTED;
      }
    }
    return out;
  }

  if (typeof value === 'string') return scrubText(value, 500);
  return value;
}

export function redactHeaders(
  headers: Record<string, string | null>,
  allowedHeaders: ReadonlySet<string>,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(headers)) {
    out[k] = allowedHeaders.has(k.toLowerCase()) ? (scrubText(v, 300) ?? '') : REDACTED;
  }
  return out;
}

/** '?customerId=123&token=abc' with only allow-listed keys kept. */
export function redactQueryString(
  url: string,
  allowedKeys: ReadonlySet<string>,
): Record<string, string> {
  const out: Record<string, string> = {};
  const qIndex = url.indexOf('?');
  if (qIndex < 0) return out;

  for (const pair of url.slice(qIndex + 1).split('&')) {
    if (!pair) continue;
    const eq = pair.indexOf('=');
    const rawKey = eq < 0 ? pair : pair.slice(0, eq);
    const rawVal = eq < 0 ? '' : pair.slice(eq + 1);
    let key: string;
    try {
      key = decodeURIComponent(rawKey);
    } catch {
      key = rawKey;
    }
    if (allowedKeys.has(key.toLowerCase())) {
      try {
        out[key] = scrubText(decodeURIComponent(rawVal), 200) ?? '';
      } catch {
        out[key] = scrubText(rawVal, 200) ?? '';
      }
    } else {
      out[key] = REDACTED;
    }
  }
  return out;
}

/**
 * Strip the query string from a URL before it is stored as the endpoint, so a
 * token accidentally passed in a query parameter never reaches the database
 * even as part of the endpoint name.
 */
export function safeEndpoint(url: string): string {
  const q = url.indexOf('?');
  return q < 0 ? url : url.slice(0, q);
}
