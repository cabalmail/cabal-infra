/** What the background answers for each kind of failure it can catch. */

import { describe, expect, it, vi } from 'vitest';
import { ApiError } from '../src/api/ApiClient';
import { AuthError } from '../src/auth/HostedUiAuth';
import { errorResponse } from '../src/messaging/errorResponse';
import { BackgroundCallError, failureMessage, isRefusal } from '../src/messaging/messages';

describe('errorResponse', () => {
  it('answers a 409 as a refusal with its sentence and status', () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const sentence = 'x@y.example is already taken. Choose another username or subdomain.';
    const body = JSON.stringify({ Error: sentence, message: sentence });
    expect(errorResponse(new ApiError(409, sentence, body))).toEqual({
      ok: false,
      error: 'refused',
      message: sentence,
      status: 409,
    });
  });

  it('answers other API errors as api, keeping the status', () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    expect(errorResponse(new ApiError(503, 'The Cabalmail server answered 503.', ''))).toEqual({
      ok: false,
      error: 'api',
      message: 'The Cabalmail server answered 503.',
      status: 503,
    });
  });

  it('keeps the session kinds, and names a token-endpoint outage as network', () => {
    expect(errorResponse(new AuthError('session-expired', 'expired'))).toMatchObject({
      error: 'session-expired',
    });
    expect(errorResponse(new AuthError('not-signed-in', 'no session'))).toMatchObject({
      error: 'not-signed-in',
    });
    expect(errorResponse(new AuthError('network', 'unreachable'))).toMatchObject({
      error: 'network',
    });
    expect(errorResponse(new AuthError('flow-failed', 'no client'))).toMatchObject({ error: 'api' });
  });

  it("answers fetch's own failure as network, keeping the words the popup recognises", () => {
    expect(errorResponse(new TypeError('Failed to fetch'))).toEqual({
      ok: false,
      error: 'network',
      message: 'TypeError: Failed to fetch',
    });
  });
});

describe('the failure helpers', () => {
  it('tell a refusal from other failures', () => {
    expect(isRefusal(new BackgroundCallError('refused', 'taken', 409))).toBe(true);
    expect(isRefusal(new BackgroundCallError('api', 'down', 502))).toBe(false);
    expect(isRefusal(new Error('refused'))).toBe(false);
  });

  it('never hand back an empty sentence', () => {
    expect(failureMessage(new BackgroundCallError('api', 'down'))).toBe('down');
    expect(failureMessage(new Error(''))).not.toBe('');
    expect(failureMessage(undefined)).not.toBe('');
  });
});
