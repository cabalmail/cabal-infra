import { ADDRESS_LIST, FOLDER_LIST } from '../constants';

const CACHE_BASES = [ADDRESS_LIST, FOLDER_LIST];

/**
 * Extract the Cognito username from an ID token. Returns null for a
 * missing or unparseable token rather than throwing — cache keying must
 * never take the app down.
 *
 * @param {string|null} token Cognito ID token (JWT)
 * @returns {string|null} the cognito:username claim, or null
 */
export function usernameFromToken(token) {
  if (!token) return null;
  try {
    // JWT payloads are base64url; atob only accepts standard base64.
    const payload = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(atob(payload))['cognito:username'] || null;
  } catch {
    return null;
  }
}

/**
 * Compose the localStorage key for a cached list. Keys are scoped per
 * user so one account's cached folders/addresses can never be served to
 * another account signing in from the same browser.
 *
 * @param {string} base ADDRESS_LIST or FOLDER_LIST
 * @param {string|null} token Cognito ID token identifying the user
 * @returns {string} the user-scoped localStorage key
 */
export function listCacheKey(base, token) {
  const user = usernameFromToken(token);
  return user ? `${base}:${user}` : base;
}

/**
 * Remove every cached folder/address list — all users' scoped keys and
 * the legacy unscoped keys from before per-user scoping. Called on login
 * and logout; login must clear too because a login does not always
 * follow an explicit logout (e.g. after session expiry).
 */
export function clearListCaches() {
  for (let i = localStorage.length - 1; i >= 0; i--) {
    const key = localStorage.key(i);
    if (CACHE_BASES.some((b) => key === b || key.startsWith(`${b}:`))) {
      localStorage.removeItem(key);
    }
  }
}
