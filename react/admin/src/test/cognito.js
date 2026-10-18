/**
 * Test helpers: unsigned JWTs and a stubbed fetch that answers the way
 * Cognito's JSON API does. Imported by the auth tests only.
 */

import { vi } from 'vitest';

function base64url(value) {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  let binary = '';
  bytes.forEach((b) => { binary += String.fromCharCode(b); });
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** A compact JWT with the given payload and a dummy signature. */
export function makeJwt(payload) {
  return `${base64url({ alg: 'RS256', kid: 'test' })}.${base64url(payload)}.c2lnbmF0dXJl`;
}

/** A Cognito reply: a fetch Response stand-in with status and body. */
export function reply(status, body) {
  let text = '';
  if (typeof body === 'string') text = body;
  else if (body !== undefined) text = JSON.stringify(body);
  return { ok: status >= 200 && status < 300, status, text: async () => text };
}

/** A Cognito error reply. */
export function cognitoError(status, type, message) {
  return reply(status, { __type: type, message });
}

/** A fetch stub answering with `replies` in order. */
export function stubFetch(...replies) {
  const fetchImpl = vi.fn();
  replies.forEach((r) => {
    if (r instanceof Error) fetchImpl.mockRejectedValueOnce(r);
    else fetchImpl.mockResolvedValueOnce(r);
  });
  return fetchImpl;
}

/** What the nth fetch call sent. */
export function sent(fetchImpl, n = 0) {
  const [url, init] = fetchImpl.mock.calls[n];
  return {
    url,
    method: init.method,
    target: init.headers['X-Amz-Target'],
    contentType: init.headers['Content-Type'],
    body: JSON.parse(init.body),
  };
}
