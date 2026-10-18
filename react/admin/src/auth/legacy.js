/**
 * Clean-up after amazon-cognito-identity-js, which the webmail used until
 * this module replaced it.
 *
 * The library kept the ID, access and refresh tokens in localStorage under
 * `CognitoIdentityServiceProvider.<clientId>.<username>.*`, plus a
 * `...<clientId>.LastAuthUser` pointer. A browser signed in before the
 * switch still holds a refresh token there for up to seven days, and
 * decision D2 says no token stays in localStorage, so the app deletes
 * them on load. Nothing reads them any more.
 */

export const LIBRARY_KEY_PREFIX = 'CognitoIdentityServiceProvider.';

function defaultStorage() {
  try {
    return typeof window !== 'undefined' ? window.localStorage : null;
  } catch {
    return null;
  }
}

/**
 * Remove every key the library wrote.
 *
 * @param {Storage|null} [storage] - defaults to localStorage.
 * @returns {number} how many keys were removed.
 */
export function purgeLibraryStorage(storage = defaultStorage()) {
  if (!storage) return 0;
  try {
    const keys = [];
    for (let i = 0; i < storage.length; i += 1) {
      const key = storage.key(i);
      if (key && key.startsWith(LIBRARY_KEY_PREFIX)) keys.push(key);
    }
    keys.forEach((key) => storage.removeItem(key));
    return keys.length;
  } catch {
    return 0;
  }
}
