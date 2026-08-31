/**
 * The config cache is per control domain. Extension storage survives a
 * rebuild of the same install, so an entry from the environment the bundle
 * used to point at must never be served to the one it points at now.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ConfigService } from '../src/config/ConfigService';
import { resetStorage } from './support/browser-stub';

function rawConfig(controlDomain: string, extensionClientId: string) {
  return {
    control_domain: controlDomain,
    domains: [{ domain: 'example.com' }],
    cognitoConfig: {
      region: 'us-east-1',
      poolData: { UserPoolId: 'pool', ClientId: 'web-client' },
      extensionClientId,
      hostedUiDomain: `cabal-${extensionClientId}`,
    },
  };
}

/** Serve each control domain its own config.json, counting the calls. */
function stubConfigEndpoint(byDomain: Record<string, ReturnType<typeof rawConfig>>) {
  const calls: string[] = [];
  vi.stubGlobal(
    'fetch',
    vi.fn(async (url: string) => {
      calls.push(url);
      const domain = new URL(url).hostname.replace(/^admin\./, '');
      const body = byDomain[domain];
      if (!body) return new Response('not found', { status: 404 });
      return new Response(JSON.stringify(body), { status: 200 });
    }),
  );
  return calls;
}

const STAGE = rawConfig('cabal-mail.example', 'stage-client');
const PROD = rawConfig('cabalmail.example', 'prod-client');

beforeEach(() => {
  resetStorage();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('ConfigService', () => {
  it('serves a cached config without refetching', async () => {
    const calls = stubConfigEndpoint({ 'cabalmail.example': PROD });
    const service = new ConfigService('cabalmail.example');

    expect((await service.get()).extensionClientId).toBe('prod-client');
    expect((await service.get()).extensionClientId).toBe('prod-client');
    expect(calls).toHaveLength(1);
  });

  it('ignores an entry cached for a different control domain', async () => {
    // The reported failure: a bundle rebuilt from stage to prod kept
    // answering with stage's Cognito client, whose registered redirect URI
    // is stage's -- so the Hosted UI returned `redirect_mismatch` before
    // rendering a login form.
    const calls = stubConfigEndpoint({
      'cabal-mail.example': STAGE,
      'cabalmail.example': PROD,
    });
    expect((await new ConfigService('cabal-mail.example').get()).extensionClientId).toBe(
      'stage-client',
    );

    const rebuilt = new ConfigService('cabalmail.example');
    expect((await rebuilt.get()).extensionClientId).toBe('prod-client');
    expect(calls).toEqual([
      'https://admin.cabal-mail.example/config.json',
      'https://admin.cabalmail.example/config.json',
    ]);
  });

  it('falls back to its own stale cache when the network fails', async () => {
    stubConfigEndpoint({ 'cabalmail.example': PROD });
    const service = new ConfigService('cabalmail.example');
    await service.get();

    const offline = vi.fn(async () => {
      throw new Error('offline');
    });
    vi.stubGlobal('fetch', offline);
    // Age the entry past the soft expiry so `get` must try the network.
    vi.useFakeTimers({ now: Date.now() + 25 * 60 * 60 * 1000 });
    try {
      expect((await service.get()).extensionClientId).toBe('prod-client');
      // Guards the test itself: without a refetch attempt this would pass
      // on the unexpired cache and prove nothing about the fallback.
      expect(offline).toHaveBeenCalledOnce();
    } finally {
      vi.useRealTimers();
    }
  });

  it('does not fall back to another domain when the network fails', async () => {
    stubConfigEndpoint({ 'cabal-mail.example': STAGE });
    await new ConfigService('cabal-mail.example').get();

    vi.stubGlobal(
      'fetch',
      vi.fn(async () => {
        throw new Error('offline');
      }),
    );
    // Serving stage's client here would be the redirect_mismatch bug with
    // an extra step: wrong is worse than unavailable.
    await expect(new ConfigService('cabalmail.example').get()).rejects.toThrow();
  });
});
