/**
 * Reading claims out of a Cognito ID token.
 *
 * No signature check: the token came straight from Cognito over TLS, and
 * what the webmail reads from it is a UI hint. Authorization stays on the
 * server (auth parity plan, D3).
 */

/**
 * Decode a JWT's payload.
 *
 * @param {string} token - a compact JWT.
 * @returns {object} the payload's claims, or `{}` when the token is
 *   malformed.
 */
export function decodeJwtPayload(token) {
  const segment = typeof token === 'string' ? token.split('.')[1] : null;
  if (!segment) return {};
  try {
    // base64url, unpadded: map back to the base64 alphabet before atob,
    // which rejects '-' and '_'. The claims are UTF-8.
    const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
    const binary = atob(base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '='));
    const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
    const payload = JSON.parse(new TextDecoder().decode(bytes));
    return payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : {};
  } catch {
    return {};
  }
}

/**
 * Whether the ID token's `cognito:groups` claim names the `admin` group.
 *
 * Whole-element match, as lambda/api/_shared/admin_limits.py does it: a
 * group whose name merely contains "admin" is not the admin group. Cognito
 * puts a JSON array in the token; the string renderings API Gateway uses
 * ("admin,users", "[admin users]") are accepted too.
 *
 * @param {string} idToken
 * @returns {boolean}
 */
export function isAdminToken(idToken) {
  const groups = decodeJwtPayload(idToken)['cognito:groups'];
  if (Array.isArray(groups)) return groups.includes('admin');
  if (typeof groups === 'string') {
    return groups.replace(/^\[+|\]+$/g, '').replace(/,/g, ' ').split(/\s+/).includes('admin');
  }
  return false;
}
