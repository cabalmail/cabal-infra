/**
 * A refused address create, across the bridge: the API's 409 in, a typed
 * failure with the server's sentence out on the content side. Before this,
 * the background flattened every API error to `api` and the raw body, so
 * the content script could not tell a refusal from an outage and showed
 * users JSON.
 *
 * Drives the real background module (importing it registers its message
 * listener) through the real content-side port, with `fetch` stubbed at
 * the wire.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { saveTokens } from '../src/auth/tokens';
import { forgetNativeControlDomain } from '../src/config/controlDomain';
import { runtimeBackgroundPort } from '../src/messaging/client';
import { BackgroundCallError } from '../src/messaging/messages';
import stub, { resetStorage } from './support/browser-stub';
import '../../chrome/src/background';

const DOMAIN = 'cabalmail.example';
const API = `https://admin.${DOMAIN}/prod`;
const TAKEN = 'taken@made-up.cabal-mail.example';
const SENTENCE = `${TAKEN} is already taken. Choose another username or subdomain.`;

/** A JWT whose only claim that matters here is an `exp` far off. */
function longLivedJwt(): string {
  const payload = btoa(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 3600 }));
  return `e30.${payload}.sig`;
}

/** Route stubbed fetches by path; records each path asked for. */
function serve(routes: Record<string, { status: number; body: unknown }>): string[] {
  const paths: string[] = [];
  vi.stubGlobal(
    'fetch',
    vi.fn(async (url: string) => {
      const path = url.replace(API, '');
      paths.push(path);
      const route = routes[path];
      if (!route) throw new TypeError('Failed to fetch');
      return new Response(JSON.stringify(route.body), { status: route.status });
    }),
  );
  return paths;
}

const send = (message: unknown) =>
  (stub.runtime as { sendMessage: (m: unknown) => Promise<unknown> }).sendMessage(message);

beforeEach(async () => {
  resetStorage();
  forgetNativeControlDomain();
  // Saves the domain, and drops whatever the background cached for an
  // earlier case.
  await send({ kind: 'set-control-domain', domain: DOMAIN });
  await (stub.storage as { local: { set: (i: Record<string, unknown>) => Promise<void> } }).local.set({
    'cabalmail.config': {
      fetchedAt: Date.now(),
      forDomain: DOMAIN,
      config: {
        controlDomain: DOMAIN,
        apiUrl: API,
        userPoolId: 'pool',
        extensionClientId: 'client',
        authDomain: `auth.${DOMAIN}`,
        region: 'us-east-1',
        apexDomains: ['cabal-mail.example'],
      },
    },
  });
  await saveTokens({ idToken: longLivedJwt(), accessToken: 'access', refreshToken: 'refresh' });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('the background bridge', () => {
  it("answers /new's 409 as a refusal carrying the server's sentence", async () => {
    serve({ '/new': { status: 409, body: { Error: SENTENCE, message: SENTENCE } } });
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const request = {
      kind: 'create-address',
      address: { username: 'taken', subdomain: 'made-up', tld: 'cabal-mail.example' },
      pending: true,
    };
    await expect(send(request)).resolves.toEqual({
      ok: false,
      error: 'refused',
      message: SENTENCE,
      status: 409,
    });

    const failure = await runtimeBackgroundPort()
      .createAddress({
        username: 'taken',
        subdomain: 'made-up',
        tld: 'cabal-mail.example',
        comment: '',
        pending: true,
      })
      .catch((err: unknown) => err);
    expect(failure).toBeInstanceOf(BackgroundCallError);
    expect(failure).toMatchObject({ kind: 'refused', message: SENTENCE, status: 409 });
  });

  it('carries the sentence of any other API error, not its JSON', async () => {
    serve({ '/new': { status: 400, body: { Error: 'Invalid subdomain' } } });
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const failure = await runtimeBackgroundPort()
      .createAddress({ username: 'a', subdomain: 'b!', tld: 'cabal-mail.example', comment: '', pending: true })
      .catch((err: unknown) => err);
    expect(failure).toMatchObject({ kind: 'api', message: 'Invalid subdomain', status: 400 });
  });

  it('reads the address list past its cache when asked to', async () => {
    const paths = serve({ '/list': { status: 200, body: { Items: [{ address: 'a@b.cabal-mail.example' }] } } });
    const port = runtimeBackgroundPort();
    await port.listAddresses();
    await port.listAddresses();
    expect(paths).toEqual(['/list']);
    await expect(port.listAddresses({ fresh: true })).resolves.toEqual(['a@b.cabal-mail.example']);
    expect(paths).toEqual(['/list', '/list']);
  });
});
