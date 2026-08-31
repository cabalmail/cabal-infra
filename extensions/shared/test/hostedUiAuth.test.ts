/**
 * The split sign-in flow: `signIn()` starts it, `completeSignIn()` finishes
 * it from the redirect URL. The tab (Safari) path is the interesting one --
 * the two halves run in separate wakes of the background worker, so
 * everything they share has to survive in storage.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { HostedUiAuth, AuthError } from '../src/auth/HostedUiAuth';
import { loadTokens } from '../src/auth/tokens';
import type { WebAuthDriver } from '../src/auth/webAuthDriver';
import { resetStorage } from './support/browser-stub';

const REDIRECT = 'https://admin.cabal-mail.example/extension-auth';
const CONFIG = { authDomain: 'pool.auth.us-east-1.amazoncognito.com', clientId: 'client-123' };

/** A JWT whose payload expires well in the future; only `exp` is read. */
function jwt(expSecondsFromNow: number): string {
  const payload = Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + expSecondsFromNow }))
    .toString('base64url');
  return `header.${payload}.signature`;
}

/** The tab driver's contract: open the tab, resolve null, redirect later. */
function tabLikeDriver(): WebAuthDriver & { authorizeUrl: string | null } {
  const driver = {
    authorizeUrl: null as string | null,
    redirectUri: () => REDIRECT,
    authorize: async (url: string) => {
      driver.authorizeUrl = url;
      return null;
    },
  };
  return driver;
}

function stubTokenEndpoint() {
  const bodies: string[] = [];
  const fetchMock = vi.fn(async (_url: string, init?: RequestInit) => {
    bodies.push(String(init?.body ?? ''));
    return new Response(
      JSON.stringify({ id_token: jwt(3600), access_token: 'access', refresh_token: 'refresh' }),
      { status: 200 },
    );
  });
  vi.stubGlobal('fetch', fetchMock);
  return { fetchMock, bodies };
}

/** Pull the `state` the flow generated back out of the authorize URL. */
function stateOf(authorizeUrl: string): string {
  return new URL(authorizeUrl).searchParams.get('state') as string;
}

beforeEach(() => {
  resetStorage();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('HostedUiAuth tab flow', () => {
  it('reports that the flow is still running, then completes from the redirect', async () => {
    const { fetchMock, bodies } = stubTokenEndpoint();
    const driver = tabLikeDriver();
    const auth = new HostedUiAuth(CONFIG, driver);

    await expect(auth.signIn()).resolves.toBe(false);
    expect(await auth.isSignedIn()).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();

    const url = driver.authorizeUrl as string;
    expect(new URL(url).searchParams.get('redirect_uri')).toBe(REDIRECT);
    expect(new URL(url).searchParams.get('code_challenge_method')).toBe('S256');

    await auth.completeSignIn(`${REDIRECT}?code=abc&state=${stateOf(url)}`);

    expect(await auth.isSignedIn()).toBe(true);
    const body = new URLSearchParams(bodies[0]);
    expect(body.get('grant_type')).toBe('authorization_code');
    expect(body.get('code')).toBe('abc');
    expect(body.get('redirect_uri')).toBe(REDIRECT);
    // The verifier survived across the two halves of the flow.
    expect(body.get('code_verifier')).toMatch(/^[\w-]{43}$/);
    expect((await loadTokens())?.refreshToken).toBe('refresh');
  });

  it('rejects a redirect whose state does not match the started flow', async () => {
    stubTokenEndpoint();
    const driver = tabLikeDriver();
    const auth = new HostedUiAuth(CONFIG, driver);
    await auth.signIn();

    await expect(auth.completeSignIn(`${REDIRECT}?code=abc&state=forged`)).rejects.toThrow(
      'state mismatch',
    );
    expect(await auth.isSignedIn()).toBe(false);
  });

  it('rejects a redirect with no flow in progress', async () => {
    stubTokenEndpoint();
    const auth = new HostedUiAuth(CONFIG, tabLikeDriver());
    await expect(auth.completeSignIn(`${REDIRECT}?code=abc&state=s`)).rejects.toThrow(
      'no sign-in is in progress',
    );
  });

  it('surfaces an error the Hosted UI reported instead of a code', async () => {
    stubTokenEndpoint();
    const driver = tabLikeDriver();
    const auth = new HostedUiAuth(CONFIG, driver);
    await auth.signIn();
    const state = stateOf(driver.authorizeUrl as string);

    await expect(
      auth.completeSignIn(`${REDIRECT}?error=invalid_request&error_description=bad+client&state=${state}`),
    ).rejects.toThrow('bad client');
  });

  it('spends a flow only once', async () => {
    stubTokenEndpoint();
    const driver = tabLikeDriver();
    const auth = new HostedUiAuth(CONFIG, driver);
    await auth.signIn();
    const redirect = `${REDIRECT}?code=abc&state=${stateOf(driver.authorizeUrl as string)}`;

    await auth.completeSignIn(redirect);
    await expect(auth.completeSignIn(redirect)).rejects.toThrow('no sign-in is in progress');
  });

  it('drops an abandoned flow on sign-out', async () => {
    stubTokenEndpoint();
    const driver = tabLikeDriver();
    const auth = new HostedUiAuth(CONFIG, driver);
    await auth.signIn();
    await auth.signOut();

    await expect(
      auth.completeSignIn(`${REDIRECT}?code=abc&state=${stateOf(driver.authorizeUrl as string)}`),
    ).rejects.toThrow('no sign-in is in progress');
  });
});

describe('HostedUiAuth identity flow', () => {
  it('completes inline when the driver observes its own redirect', async () => {
    stubTokenEndpoint();
    let seen = '';
    const driver: WebAuthDriver = {
      redirectUri: () => 'https://abc.chromiumapp.org/',
      authorize: async (url) => {
        seen = url;
        return `https://abc.chromiumapp.org/?code=xyz&state=${stateOf(url)}`;
      },
    };
    const auth = new HostedUiAuth(CONFIG, driver);

    await expect(auth.signIn()).resolves.toBe(true);
    expect(seen).toContain('/oauth2/authorize');
    expect(await auth.isSignedIn()).toBe(true);
  });

  it('clears the pending flow when the interactive leg fails', async () => {
    stubTokenEndpoint();
    const driver: WebAuthDriver = {
      redirectUri: () => 'https://abc.chromiumapp.org/',
      authorize: async () => {
        throw new Error('user cancelled');
      },
    };
    const auth = new HostedUiAuth(CONFIG, driver);

    await expect(auth.signIn()).rejects.toThrow(AuthError);
    await expect(auth.completeSignIn('https://abc.chromiumapp.org/?code=x&state=y')).rejects.toThrow(
      'no sign-in is in progress',
    );
  });
});
