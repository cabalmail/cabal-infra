/**
 * ApiClient against the wire shapes the Lambda endpoints actually return.
 * These deliberately stub `fetch` rather than the client: #1418 was a parse
 * of a response shape `/list` never produced, and every test above the
 * wire passed while the live endpoint returned nothing usable.
 */

import { afterEach, describe, expect, it, vi } from 'vitest';
import { ApiClient, ApiError, serverSentence } from '../src/api/ApiClient';
import type { HostedUiAuth } from '../src/auth/HostedUiAuth';

const auth = {
  idToken: async () => 'id-token',
  forceRefresh: async () => 'id-token',
  signOut: async () => {},
} as unknown as HostedUiAuth;

function respond(body: unknown, status = 200) {
  const calls: { url: string; init?: RequestInit }[] = [];
  vi.stubGlobal(
    'fetch',
    vi.fn(async (url: string, init?: RequestInit) => {
      calls.push({ url, init });
      return new Response(JSON.stringify(body), { status });
    }),
  );
  return calls;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('ApiClient.listAddresses', () => {
  it('reads the Items array /list actually returns', async () => {
    // Verbatim shape of lambda/api/list/function.py's response, including
    // the projection fields the extension does not model.
    const calls = respond({
      Items: [
        {
          address: 'ab12cd34@x9y8z7w6.cabal-mail.example',
          username: 'ab12cd34',
          subdomain: 'x9y8z7w6',
          tld: 'cabal-mail.example',
          comment: 'github.com',
          user: 'claude',
          favorite: false,
          suspended: false,
          pending: true,
        },
        {
          address: 'second@x9y8z7w6.cabal-mail.example',
          username: 'second',
          subdomain: 'x9y8z7w6',
          tld: 'cabal-mail.example',
          comment: '',
          user: 'claude/other',
          favorite: true,
          suspended: false,
          pending: false,
        },
      ],
    });

    const rows = await new ApiClient('https://admin.cabal-mail.example/prod', auth).listAddresses();

    expect(rows.map((r) => r.address)).toEqual([
      'ab12cd34@x9y8z7w6.cabal-mail.example',
      'second@x9y8z7w6.cabal-mail.example',
    ]);
    expect(rows[0]?.pending).toBe(true);
    expect(calls[0]?.url).toBe('https://admin.cabal-mail.example/prod/list');
    expect((calls[0]?.init?.headers as Record<string, string>).Authorization).toBe('id-token');
  });

  it('returns an empty list for an empty account, not for a broken one', async () => {
    respond({ Items: [] });
    await expect(
      new ApiClient('https://admin.cabal-mail.example/prod', auth).listAddresses(),
    ).resolves.toEqual([]);
  });

  it('throws on a shape the endpoint does not return, rather than reporting nothing', async () => {
    // The pre-#1418 client read this shape and silently returned [].
    respond({ addresses: [{ address: 'x@y.z' }] });
    await expect(
      new ApiClient('https://admin.cabal-mail.example/prod', auth).listAddresses(),
    ).rejects.toThrow(ApiError);
  });
});

describe('ApiClient.listMyDomains', () => {
  it('reads the Domains array /list_my_domains returns', async () => {
    respond({ Domains: ['cabal-mail.com', 'cabal-mail.io'] });
    await expect(
      new ApiClient('https://admin.cabal-mail.example/prod', auth).listMyDomains(),
    ).resolves.toEqual(['cabal-mail.com', 'cabal-mail.io']);
  });
});

describe('ApiClient errors', () => {
  const client = () => new ApiClient('https://admin.cabal-mail.example/prod', auth);
  const create = () => client().newAddress({ username: 'taken', subdomain: 'made-up', tld: 'cabal-mail.example' });

  it("carries /new's 409 sentence and status, keeping the raw body aside", async () => {
    // Verbatim shape of lambda/api/new/function.py's conflict_response.
    const sentence = 'taken@made-up.cabal-mail.example is already taken. Choose another username or subdomain.';
    respond({ Error: sentence, message: sentence }, 409);
    const err = await create().catch((e: unknown) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(err).toMatchObject({ status: 409, message: sentence });
    expect((err as ApiError).body).toContain('"message"');
  });

  it('reads Error when there is no message, as /new\'s 400 and 403 send', async () => {
    respond({ Error: 'Not permitted to create addresses on "cabal-mail.example"' }, 403);
    await expect(create()).rejects.toMatchObject({
      status: 403,
      message: 'Not permitted to create addresses on "cabal-mail.example"',
    });
  });

  it('shows no raw exception text from a 500', async () => {
    // /new's 500 carries the exception under a lower-case `error`.
    respond({ address: 'a@b.cabal-mail.example', error: 'An error occurred (ProvisionedThroughputExceededException)' }, 500);
    await expect(create()).rejects.toMatchObject({
      status: 500,
      message: 'The Cabalmail server answered 500.',
    });
  });

  it('reads API Gateway\'s own message, and falls back on a body that is not JSON', () => {
    expect(serverSentence('{"message": "Internal server error"}')).toBe('Internal server error');
    expect(serverSentence('<html>Bad Gateway</html>')).toBeNull();
    expect(serverSentence('{"status": "There is no folder called X"}')).toBeNull();
    expect(serverSentence('{"message": "  "}')).toBeNull();
  });
});
