import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createSession, hasStoredSession, SESSION_STORAGE_KEY } from './session';
import { createCognitoClient } from './cognito';
import { CognitoError, isSignInRequired } from './errors';
import { makeJwt, stubFetch, reply, cognitoError, sent } from '../test/cognito';

const HOUR = 60 * 60 * 1000;
let clock;
const now = () => clock;

const ADMIN_ID = makeJwt({ 'cognito:groups': ['admin'], 'cognito:username': 'alice' });
const PLAIN_ID = makeJwt({ 'cognito:username': 'alice' });

function tokens(overrides = {}) {
  return {
    idToken: PLAIN_ID,
    accessToken: 'access-1',
    refreshToken: 'refresh-1',
    expiresAt: clock + 12 * HOUR,
    ...overrides,
  };
}

function refreshReply(idToken = ADMIN_ID, extra = {}) {
  return reply(200, { AuthenticationResult: { IdToken: idToken, AccessToken: 'access-2', ExpiresIn: 43200, ...extra } });
}

function setup(...replies) {
  const fetchImpl = stubFetch(...replies);
  const client = createCognitoClient({ region: 'us-east-1', clientId: 'main-client', fetchImpl, now });
  const session = createSession({ client, storage: window.sessionStorage, now });
  return { fetchImpl, client, session };
}

function stored() {
  return JSON.parse(window.sessionStorage.getItem(SESSION_STORAGE_KEY));
}

beforeEach(() => {
  clock = 1_800_000_000_000;
  window.sessionStorage.clear();
  window.localStorage.clear();
});

describe('persistence (D2: sessionStorage, never localStorage)', () => {
  it('persists to sessionStorage by default', () => {
    const client = createCognitoClient({ region: 'us-east-1', clientId: 'c', fetchImpl: stubFetch(), now });
    createSession({ client, now }).establish(tokens(), 'alice');
    expect(stored()).toEqual({ username: 'alice', refreshToken: 'refresh-1' });
    expect(window.localStorage.length).toBe(0);
  });

  it('keeps the refresh token and username in sessionStorage, and the ID and access tokens out of it', () => {
    const { session } = setup();
    session.establish(tokens(), 'alice');
    expect(stored()).toEqual({ username: 'alice', refreshToken: 'refresh-1' });
    const raw = window.sessionStorage.getItem(SESSION_STORAGE_KEY);
    expect(raw).not.toContain(PLAIN_ID);
    expect(raw).not.toContain('access-1');
  });

  it('writes nothing to localStorage across sign-in, refresh and sign-out', async () => {
    const setItem = vi.spyOn(Storage.prototype, 'setItem');
    try {
      const { session } = setup(refreshReply());
      session.establish(tokens(), 'alice');
      await session.refresh();
      session.clear();
      const localWrites = setItem.mock.contexts.filter((ctx) => ctx === window.localStorage);
      expect(localWrites).toHaveLength(0);
      expect(window.localStorage.length).toBe(0);
    } finally {
      setItem.mockRestore();
    }
  });

  it('removes the stored session on clear', () => {
    const { session } = setup();
    session.establish(tokens(), 'alice');
    session.clear();
    expect(window.sessionStorage.getItem(SESSION_STORAGE_KEY)).toBeNull();
    expect(session.current()).toBeNull();
  });

  it('works in memory with no storage at all', async () => {
    const fetchImpl = stubFetch();
    const client = createCognitoClient({ region: 'us-east-1', clientId: 'c', fetchImpl, now });
    const session = createSession({ client, storage: null, now });
    session.establish(tokens(), 'alice');
    expect(await session.idToken()).toBe(PLAIN_ID);
    expect(await session.restore()).not.toBeNull();
  });

  it('survives storage that throws', async () => {
    const broken = {
      getItem: () => { throw new Error('SecurityError'); },
      setItem: () => { throw new Error('QuotaExceededError'); },
      removeItem: () => { throw new Error('SecurityError'); },
    };
    const client = createCognitoClient({ region: 'us-east-1', clientId: 'c', fetchImpl: stubFetch(), now });
    const session = createSession({ client, storage: broken, now });
    session.establish(tokens(), 'alice');
    expect(await session.idToken()).toBe(PLAIN_ID);
    session.clear();
    expect(session.current()).toBeNull();
    expect(await session.restore()).toBeNull();
  });
});

describe('tokens and refresh', () => {
  it('hands out the current tokens without calling Cognito while they are fresh', async () => {
    const { session, fetchImpl } = setup();
    session.establish(tokens(), 'alice');
    expect(await session.idToken()).toBe(PLAIN_ID);
    expect(await session.accessToken()).toBe('access-1');
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('refreshes inside the five-minute leeway before expiry', async () => {
    const { session, fetchImpl } = setup(refreshReply());
    session.establish(tokens({ expiresAt: clock + 4 * 60 * 1000 }), 'alice');
    expect(await session.idToken()).toBe(ADMIN_ID);
    expect(sent(fetchImpl).body.AuthParameters).toEqual({ REFRESH_TOKEN: 'refresh-1' });
  });

  it('refreshes an expired session instead of signing out (the library-era 12-hour sign-out)', async () => {
    const { session } = setup(refreshReply());
    session.establish(tokens(), 'alice');
    clock += 13 * HOUR;
    expect(await session.accessToken()).toBe('access-2');
    expect(session.current().expiresAt).toBe(clock + 43200 * 1000);
  });

  it('sends one refresh for any number of concurrent callers', async () => {
    const { session, fetchImpl } = setup(refreshReply());
    session.establish(tokens({ expiresAt: clock - 1 }), 'alice');
    const results = await Promise.all([
      session.idToken(), session.idToken(), session.accessToken(), session.refresh(),
    ]);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(results.slice(0, 2)).toEqual([ADMIN_ID, ADMIN_ID]);
    expect(results[2]).toBe('access-2');
  });

  it('refreshes again after a refresh completes', async () => {
    const { session, fetchImpl } = setup(refreshReply(), refreshReply(PLAIN_ID));
    session.establish(tokens(), 'alice');
    await session.refresh();
    await session.refresh();
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it('stores a rotated refresh token', async () => {
    const { session } = setup(refreshReply(ADMIN_ID, { RefreshToken: 'refresh-2' }));
    session.establish(tokens(), 'alice');
    await session.refresh();
    expect(stored()).toEqual({ username: 'alice', refreshToken: 'refresh-2' });
  });

  it('re-derives isAdmin on refresh and tells subscribers', async () => {
    const { session } = setup(refreshReply(ADMIN_ID));
    const seen = [];
    session.subscribe((s) => seen.push(s && s.isAdmin));
    session.establish(tokens({ idToken: PLAIN_ID }), 'alice');
    await session.refresh();
    expect(seen).toEqual([false, true]);
  });

  it('stops telling an unsubscribed listener', () => {
    const { session } = setup();
    const listener = vi.fn();
    const unsubscribe = session.subscribe(listener);
    unsubscribe();
    session.establish(tokens(), 'alice');
    expect(listener).not.toHaveBeenCalled();
  });

  it('says "sign in" when there is no session', async () => {
    const { session } = setup();
    const err = await session.idToken().catch((e) => e);
    expect(isSignInRequired(err)).toBe(true);
  });
});

describe('refresh failures', () => {
  it('ends the session when Cognito refuses the refresh token', async () => {
    const { session } = setup(cognitoError(400, 'NotAuthorizedException', 'Refresh Token has expired'));
    const seen = [];
    session.establish(tokens({ expiresAt: clock - 1 }), 'alice');
    session.subscribe((s) => seen.push(s));
    const err = await session.idToken().catch((e) => e);
    expect(err.code).toBe('SessionExpired');
    expect(isSignInRequired(err)).toBe(true);
    expect(err.cause.code).toBe('NotAuthorizedException');
    expect(session.current()).toBeNull();
    expect(window.sessionStorage.getItem(SESSION_STORAGE_KEY)).toBeNull();
    expect(seen).toEqual([null]);
  });

  it('ends the session when a pool trigger refuses to issue tokens', async () => {
    const { session } = setup(cognitoError(400, 'UserLambdaValidationException',
      'PreTokenGeneration failed with error This account requires multi-factor authentication.'));
    session.establish(tokens(), 'alice');
    const err = await session.refresh().catch((e) => e);
    expect(err.code).toBe('SessionExpired');
    expect(session.current()).toBeNull();
  });

  it('keeps the session through a network failure', async () => {
    const { session } = setup(new TypeError('Failed to fetch'));
    session.establish(tokens({ expiresAt: clock - 1 }), 'alice');
    const err = await session.idToken().catch((e) => e);
    expect(err.code).toBe('NetworkError');
    expect(isSignInRequired(err)).toBe(false);
    expect(stored()).toEqual({ username: 'alice', refreshToken: 'refresh-1' });
  });

  it('keeps the session through throttling and server errors', async () => {
    const { session } = setup(
      cognitoError(400, 'TooManyRequestsException', 'Rate exceeded'),
      cognitoError(500, 'InternalErrorException', 'Internal error'),
      refreshReply(),
    );
    session.establish(tokens({ expiresAt: clock - 1 }), 'alice');
    expect((await session.idToken().catch((e) => e)).code).toBe('TooManyRequestsException');
    expect((await session.idToken().catch((e) => e)).code).toBe('InternalErrorException');
    expect(await session.idToken()).toBe(ADMIN_ID);
  });
});

describe('restore after a reload', () => {
  it('says synchronously whether there is a session to restore', () => {
    expect(hasStoredSession()).toBe(false);
    window.sessionStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify({ username: 'a', refreshToken: 'r' }));
    expect(hasStoredSession()).toBe(true);
    expect(hasStoredSession(null)).toBe(false);
    expect(hasStoredSession({ getItem: () => { throw new Error('SecurityError'); } })).toBe(false);
  });

  it('has nothing to restore in a new tab', async () => {
    const { session, fetchImpl } = setup();
    expect(await session.restore()).toBeNull();
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('refreshes from the stored token and comes back with the username', async () => {
    window.sessionStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify({ username: 'alice', refreshToken: 'refresh-1' }));
    const { session, fetchImpl } = setup(refreshReply(ADMIN_ID));
    const restored = await session.restore();
    expect(sent(fetchImpl).body.AuthParameters).toEqual({ REFRESH_TOKEN: 'refresh-1' });
    expect(restored).toMatchObject({ username: 'alice', idToken: ADMIN_ID, accessToken: 'access-2', isAdmin: true });
    expect(session.current()).toEqual(restored);
  });

  it('comes back signed out, and forgets the token, when Cognito refuses it', async () => {
    window.sessionStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify({ username: 'alice', refreshToken: 'stale' }));
    const { session } = setup(cognitoError(400, 'NotAuthorizedException', 'Invalid Refresh Token'));
    expect(await session.restore()).toBeNull();
    expect(window.sessionStorage.getItem(SESSION_STORAGE_KEY)).toBeNull();
  });

  it('rejects when Cognito is unreachable but keeps the token for the next try', async () => {
    window.sessionStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify({ username: 'alice', refreshToken: 'refresh-1' }));
    const { session } = setup(new TypeError('Failed to fetch'), refreshReply());
    const err = await session.restore().catch((e) => e);
    expect(err.code).toBe('NetworkError');
    expect(session.current()).toBeNull();
    expect(stored()).toEqual({ username: 'alice', refreshToken: 'refresh-1' });
    expect(await session.restore()).toMatchObject({ username: 'alice' });
  });

  it('ignores a malformed stored value', async () => {
    window.sessionStorage.setItem(SESSION_STORAGE_KEY, '{not json');
    const { session, fetchImpl } = setup();
    expect(await session.restore()).toBeNull();
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('returns the live session without a call when one is already up', async () => {
    const { session, fetchImpl } = setup();
    session.establish(tokens(), 'alice');
    expect(await session.restore()).toMatchObject({ username: 'alice', idToken: PLAIN_ID });
    expect(fetchImpl).not.toHaveBeenCalled();
  });
});

describe('races', () => {
  // A refresh whose reply the test releases by hand.
  function heldRefresh() {
    let release;
    const client = {
      refresh: vi.fn(() => new Promise((resolve, reject) => { release = { resolve, reject }; })),
    };
    return { client, release: () => release };
  }

  it('does not bring a session back when sign-out lands mid-refresh', async () => {
    const held = heldRefresh();
    const session = createSession({ client: held.client, storage: window.sessionStorage, now });
    session.establish(tokens({ expiresAt: clock - 1 }), 'alice');
    const pending = session.idToken();
    session.clear();
    held.release().resolve(tokens({ idToken: ADMIN_ID }));
    const err = await pending.catch((e) => e);
    expect(err).toBeInstanceOf(CognitoError);
    expect(isSignInRequired(err)).toBe(true);
    expect(session.current()).toBeNull();
    expect(window.sessionStorage.getItem(SESSION_STORAGE_KEY)).toBeNull();
  });

  it("does not hand the old account's refresh to a caller after a sign-in as someone else", async () => {
    const held = heldRefresh();
    const session = createSession({ client: held.client, storage: window.sessionStorage, now });
    session.establish(tokens({ expiresAt: clock - 1 }), 'alice');
    const pending = session.idToken();
    session.establish(tokens({ idToken: 'bob-id', refreshToken: 'bob-refresh' }), 'bob');
    held.release().resolve(tokens({ idToken: 'alice-id' }));
    expect(isSignInRequired(await pending.catch((e) => e))).toBe(true);
    expect(session.current()).toMatchObject({ username: 'bob', idToken: 'bob-id' });
    expect(stored()).toEqual({ username: 'bob', refreshToken: 'bob-refresh' });
  });

  it('does not clear a new sign-in when a stale refresh is refused afterwards', async () => {
    const held = heldRefresh();
    const session = createSession({ client: held.client, storage: window.sessionStorage, now });
    session.establish(tokens({ expiresAt: clock - 1 }), 'alice');
    const pending = session.idToken();
    session.establish(tokens({ idToken: 'bob-id', refreshToken: 'bob-refresh' }), 'bob');
    held.release().reject(new CognitoError('NotAuthorizedException', 'Refresh Token has expired', { status: 400 }));
    expect(isSignInRequired(await pending.catch((e) => e))).toBe(true);
    expect(session.current()).toMatchObject({ username: 'bob' });
    expect(stored()).toEqual({ username: 'bob', refreshToken: 'bob-refresh' });
  });

  it('lets a sign-in during a slow restore win', async () => {
    window.sessionStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify({ username: 'alice', refreshToken: 'refresh-1' }));
    const held = heldRefresh();
    const session = createSession({ client: held.client, storage: window.sessionStorage, now });
    const restoring = session.restore();
    session.establish(tokens({ idToken: 'bob-id', refreshToken: 'bob-refresh' }), 'bob');
    held.release().reject(new TypeError('Failed to fetch'));
    expect(await restoring).toMatchObject({ username: 'bob', idToken: 'bob-id' });
    expect(session.current()).toMatchObject({ username: 'bob' });
  });
});
