/* =========================================================================
   Bucketing for the `auth_results` envelope field — the SPF/DKIM/DMARC
   verdicts stamped by smtp-in (Authentication-Results, RFC 8601) and
   parsed server-side into `{"spf": ..., "dkim": ..., "dmarc": ...}`.
   Values are lowercased RFC 8601 result tokens (pass, fail, none, neutral,
   softfail, temperror, permerror, policy). A method key may be absent
   (method not evaluated); the whole field may be null or missing (mail
   that predates the feature, or bypassed smtp-in). Absent data must NEVER
   render as a pass.
   ========================================================================= */

// Message-level display states.
export const AUTH_OK = 'ok';
export const AUTH_WARNING = 'warning';
export const AUTH_NOT_VERIFIED = 'not-verified';

// Per-method chip colorings.
export const VERDICT_OK = 'ok';
export const VERDICT_BAD = 'bad';
export const VERDICT_NEUTRAL = 'neutral';

// Shared warning copy. Deliberately says "could not be authenticated",
// not "dangerous" — forwarding legitimately breaks these checks.
export const AUTH_WARNING_COPY = 'This message could not be authenticated as '
  + 'coming from its claimed sender. Forwarded mail often fails these checks.';

/**
 * Normalizes a result token: lowercased string, or null for anything that
 * isn't a string (absent method, malformed payload).
 * @param {*} token raw method value from auth_results
 * @returns {?string} lowercased token or null
 */
function normalize(token) {
  return typeof token === 'string' ? token.toLowerCase() : null;
}

/**
 * Buckets an envelope's auth_results into one of the three display states:
 *   - AUTH_OK: dmarc passed;
 *   - AUTH_WARNING: dmarc failed hard (fail/permerror), or dmarc was not
 *     evaluated while both spf and dkim failed;
 *   - AUTH_NOT_VERIFIED: everything else — no data at all, or the
 *     softfail/neutral/none middle ground. The quiet default.
 * @param {?Object} authResults the envelope's auth_results field
 * @returns {string} one of AUTH_OK, AUTH_WARNING, AUTH_NOT_VERIFIED
 */
export function authState(authResults) {
  if (!authResults || typeof authResults !== 'object') return AUTH_NOT_VERIFIED;
  const dmarc = normalize(authResults.dmarc);
  const spf = normalize(authResults.spf);
  const dkim = normalize(authResults.dkim);
  if (dmarc === 'pass') return AUTH_OK;
  if (dmarc === 'fail' || dmarc === 'permerror') return AUTH_WARNING;
  if (!dmarc && spf === 'fail' && dkim === 'fail') return AUTH_WARNING;
  return AUTH_NOT_VERIFIED;
}

/**
 * Maps a single method's result token to a chip coloring: pass is ok,
 * fail/permerror is bad, everything else (including absent) is neutral.
 * @param {*} token raw method value from auth_results
 * @returns {string} one of VERDICT_OK, VERDICT_BAD, VERDICT_NEUTRAL
 */
export function methodVerdict(token) {
  const t = normalize(token);
  if (t === 'pass') return VERDICT_OK;
  if (t === 'fail' || t === 'permerror') return VERDICT_BAD;
  return VERDICT_NEUTRAL;
}

/**
 * True when auth_results carries at least one evaluated method — i.e. the
 * reading view has verdicts to chip rather than the muted "Not verified".
 * @param {?Object} authResults the envelope's auth_results field
 * @returns {boolean} whether any of spf/dkim/dmarc is present
 */
export function hasAuthData(authResults) {
  if (!authResults || typeof authResults !== 'object') return false;
  return ['spf', 'dkim', 'dmarc'].some((m) => typeof authResults[m] === 'string');
}
