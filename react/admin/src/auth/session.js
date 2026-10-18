/**
 * The webmail's signed-in session: the tokens, their refresh, and what
 * survives a reload.
 *
 * Persistence is decision D2 of docs/1.x/auth-parity-plan.md: the refresh
 * token and username go to sessionStorage and nothing goes to
 * localStorage. A reload stays signed in by refreshing; a new tab, or a
 * tab closed and reopened, signs in again. The ID and access tokens live
 * only in memory here.
 *
 * Refresh is single-flight: however many callers find the token stale at
 * once, Cognito sees one REFRESH_TOKEN_AUTH and they all get its result.
 */

import { CognitoError } from './errors';
import { isAdminToken } from './jwt';

export const SESSION_STORAGE_KEY = 'cabal.auth.session';

// Refresh this long before the tokens expire, so a token handed to an API
// call doesn't expire on its way there. The native kits use the same.
const REFRESH_LEEWAY_MS = 5 * 60 * 1000;

function defaultStorage() {
  try {
    return typeof window !== 'undefined' ? window.sessionStorage : null;
  } catch {
    // Storage blocked (a sandboxed frame, some privacy settings): the
    // session still works, it just doesn't survive a reload.
    return null;
  }
}

/**
 * Cognito refused the refresh outright: the token expired, was revoked,
 * or the user was disabled or deleted, or a pool trigger refused to issue
 * tokens. Throttling and server errors are not refusals; the session is
 * kept for the next try.
 */
function refreshRefused(err) {
  if (!(err instanceof CognitoError) || typeof err.status !== 'number') return false;
  if (err.status < 400 || err.status >= 500) return false;
  return !['TooManyRequestsException', 'LimitExceededException'].includes(err.code);
}

/**
 * @param {object} options
 * @param {{refresh: (refreshToken: string) => Promise<object>}} options.client
 *   - the Cognito client the tokens came from (cognito.js).
 * @param {Storage|null} [options.storage] - defaults to sessionStorage;
 *   null keeps the session in memory only.
 * @param {() => number} [options.now] - epoch ms; defaults to Date.now.
 */
export function createSession({ client, storage = defaultStorage(), now = Date.now }) {
  let tokens = null;
  let username = null;
  let inflight = null;
  // Bumped whenever the session is replaced or cleared, so a refresh that
  // was in flight across a sign-out or a sign-in can't write its result
  // back over the newer state.
  let generation = 0;
  const listeners = new Set();

  function readStored() {
    try {
      const raw = storage && storage.getItem(SESSION_STORAGE_KEY);
      const parsed = raw ? JSON.parse(raw) : null;
      return parsed && typeof parsed.refreshToken === 'string' ? parsed : null;
    } catch {
      return null;
    }
  }

  function writeStored() {
    try {
      if (!storage) return;
      if (tokens && tokens.refreshToken) {
        storage.setItem(SESSION_STORAGE_KEY, JSON.stringify({
          username,
          refreshToken: tokens.refreshToken,
        }));
      } else {
        storage.removeItem(SESSION_STORAGE_KEY);
      }
    } catch {
      // Quota or blocked storage: memory still holds the session.
    }
  }

  function snapshot() {
    if (!tokens) return null;
    return {
      username,
      idToken: tokens.idToken,
      accessToken: tokens.accessToken,
      expiresAt: tokens.expiresAt,
      isAdmin: isAdminToken(tokens.idToken),
    };
  }

  function notify() {
    const current = snapshot();
    listeners.forEach((listener) => {
      try {
        listener(current);
      } catch (e) {
        console.error('[auth] session listener failed', e);
      }
    });
  }

  function fresh() {
    return !!tokens && now() < tokens.expiresAt - REFRESH_LEEWAY_MS;
  }

  function clear() {
    generation += 1;
    inflight = null;
    const had = tokens !== null;
    tokens = null;
    username = null;
    try {
      if (storage) storage.removeItem(SESSION_STORAGE_KEY);
    } catch {
      // Nothing more to do; the memory copy is gone.
    }
    if (had) notify();
  }

  function refresh() {
    if (inflight) return inflight;
    const refreshToken = tokens ? tokens.refreshToken : null;
    if (!refreshToken) {
      return Promise.reject(new CognitoError('NotSignedIn', 'Not signed in.'));
    }
    const started = generation;
    // The session was replaced or cleared while this refresh was out. Its
    // caller asked on behalf of the old session, so it gets neither the
    // old account's new tokens nor the new account's.
    const superseded = (cause) => new CognitoError(
      'NotSignedIn',
      'The session changed while it was being refreshed.',
      cause === undefined ? {} : { cause },
    );
    const attempt = client.refresh(refreshToken).then(
      (next) => {
        if (generation !== started) throw superseded();
        tokens = next;
        writeStored();
        notify();
        return snapshot();
      },
      (err) => {
        if (generation !== started) throw superseded(err);
        if (refreshRefused(err)) {
          clear();
          throw new CognitoError(
            'SessionExpired',
            'Your session has expired. Please sign in again.',
            { cause: err },
          );
        }
        throw err;
      },
    ).finally(() => {
      if (inflight === attempt) inflight = null;
    });
    inflight = attempt;
    return attempt;
  }

  async function valid() {
    if (fresh()) return snapshot();
    if (!tokens) throw new CognitoError('NotSignedIn', 'Not signed in.');
    return refresh();
  }

  return {
    /**
     * Start a session from a completed sign-in, replacing any other.
     *
     * @param {object} newTokens - from the client's signIn or
     *   respondToMfaChallenge.
     * @param {string} name - the username signed in as.
     */
    establish(newTokens, name) {
      generation += 1;
      inflight = null;
      tokens = newTokens;
      username = name;
      writeStored();
      notify();
    },

    /**
     * Pick up the session a reload left in sessionStorage.
     *
     * @returns {Promise<object|null>} the snapshot, or null when there is
     *   nothing to restore or Cognito refused the stored refresh token.
     *   Any other failure (offline, Cognito unavailable) rejects and leaves
     *   the stored token for the next try.
     */
    async restore() {
      if (tokens) return valid();
      const stored = readStored();
      if (!stored) return null;
      generation += 1;
      const mine = generation;
      tokens = { idToken: null, accessToken: null, refreshToken: stored.refreshToken, expiresAt: 0 };
      username = stored.username || null;
      try {
        return await refresh();
      } catch (err) {
        if (err instanceof CognitoError && err.code === 'SessionExpired') return null;
        // A sign-in or sign-out landed while the restore was in flight;
        // that state wins, whatever it is.
        if (generation !== mine) return tokens && tokens.idToken ? snapshot() : null;
        // Not refused, just not reachable: drop the half-built memory
        // state but keep what's stored.
        tokens = null;
        username = null;
        throw err;
      }
    },

    /** @returns {Promise<string>} an ID token with at least five minutes left. */
    async idToken() {
      return (await valid()).idToken;
    },

    /** @returns {Promise<string>} an access token with at least five minutes left. */
    async accessToken() {
      return (await valid()).accessToken;
    },

    /**
     * Refresh now, whatever the expiry says (after an API call rejected the
     * token, say).
     *
     * @returns {Promise<object>} the new snapshot.
     */
    refresh,

    /**
     * The current tokens without refreshing, for render-time reads.
     *
     * @returns {{username: string|null, idToken: string, accessToken: string,
     *   expiresAt: number, isAdmin: boolean}|null}
     */
    current() {
      return tokens && tokens.idToken ? snapshot() : null;
    },

    /** End the session here: memory and sessionStorage. */
    clear,

    /**
     * Be told about every change: sign-in, refresh, sign-out, expiry.
     *
     * @param {(snapshot: object|null) => void} listener
     * @returns {() => void} unsubscribe.
     */
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}
