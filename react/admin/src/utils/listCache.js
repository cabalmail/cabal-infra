import {
  ADDRESS_LIST,
  FOLDER_COLLAPSED_ALL,
  FOLDER_COLLAPSED_PATHS,
  FOLDER_COLLAPSED_SUB,
  FOLDER_LIST,
} from '../constants';

const CACHE_BASES = [ADDRESS_LIST, FOLDER_LIST];

// Folder-rail collapse state is keyed per user like the caches above, but
// it is a preference rather than a cache: the scoped keys are deliberately
// NOT swept, so each account keeps its own rail layout across sessions.
// Only the pre-scoping bare keys are removed — they belong to whoever last
// used this browser and would otherwise sit here forever. The bare key is
// also where state lands when the token yields no username, and that
// unknown-user bucket is exactly what should not survive a session.
const LEGACY_UI_STATE_KEYS = [
  FOLDER_COLLAPSED_SUB,
  FOLDER_COLLAPSED_ALL,
  FOLDER_COLLAPSED_PATHS,
];

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
 * Compose a user-scoped localStorage key. Keys are scoped per user so one
 * account's cached folders/addresses can never be served to another
 * account signing in from the same browser, and so per-user UI state (the
 * folder rail's collapse state) is never inherited by the next account.
 *
 * @param {string} base ADDRESS_LIST, FOLDER_LIST or a FOLDER_COLLAPSED_* key
 * @param {string|null} token Cognito ID token identifying the user
 * @returns {string} the user-scoped localStorage key
 */
export function listCacheKey(base, token) {
  const user = usernameFromToken(token);
  return user ? `${base}:${user}` : base;
}

/**
 * Remove every cached folder/address list — all users' scoped keys and
 * the legacy unscoped keys from before per-user scoping — plus the
 * unscoped folder-rail collapse state left behind by the same era. Called
 * on login and logout; login must clear too because a login does not
 * always follow an explicit logout (e.g. after session expiry).
 */
export function clearListCaches() {
  for (let i = localStorage.length - 1; i >= 0; i--) {
    const key = localStorage.key(i);
    const isCache = CACHE_BASES.some((b) => key === b || key.startsWith(`${b}:`));
    if (isCache || LEGACY_UI_STATE_KEYS.includes(key)) {
      localStorage.removeItem(key);
    }
  }
}
