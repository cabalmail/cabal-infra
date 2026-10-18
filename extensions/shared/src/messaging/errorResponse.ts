/**
 * How the background answers a request that threw: the bridge's failure
 * arm, with a kind a caller can branch on and a sentence a person can read.
 * Kept out of background.ts so it can be tested without loading the worker.
 */

import { ApiError } from '../api/ApiClient';
import { AuthError } from '../auth/HostedUiAuth';
import type { BackgroundResponse } from './messages';

export function errorResponse(err: unknown): Extract<BackgroundResponse, { ok: false }> {
  if (err instanceof AuthError) {
    const error =
      err.reason === 'session-expired'
        ? 'session-expired'
        : err.reason === 'not-signed-in'
          ? 'not-signed-in'
          : err.reason === 'network'
            ? 'network'
            : 'api';
    return { ok: false, error, message: err.message };
  }
  if (err instanceof ApiError) {
    // The raw body stays in the worker's console; the bridge carries the
    // sentence ApiClient read out of it.
    if (err.body) console.warn(`[cabalmail] API answered ${err.status}:`, err.body);
    return {
      ok: false,
      error: err.status === 409 ? 'refused' : 'api',
      message: err.message,
      status: err.status,
    };
  }
  // fetch() rejects with a TypeError when the request never got an answer.
  // String() keeps its "Failed to fetch", which the popup turns into advice.
  if (err instanceof TypeError) return { ok: false, error: 'network', message: String(err) };
  return { ok: false, error: 'api', message: String(err) };
}
