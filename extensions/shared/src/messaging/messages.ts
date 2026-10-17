/**
 * Content-script / popup <-> background message schema. The background
 * service worker is the auth boundary: it alone holds tokens and talks to
 * the Cabalmail API. Everything else asks via these messages.
 */

import type { Address, Domain } from '../models/index';

export type BackgroundRequest =
  | { kind: 'get-auth-state' }
  | { kind: 'get-control-domain' }
  | { kind: 'set-control-domain'; domain: string }
  | { kind: 'sign-in' }
  | { kind: 'sign-out' }
  | { kind: 'list-domains' }
  // `fresh` skips the background's short-lived cache: a create the user just
  // asked for must not trust a list that predates an address made elsewhere.
  | { kind: 'list-addresses'; fresh?: boolean }
  | {
      kind: 'create-address';
      address: { tld: string; subdomain: string; username: string; comment?: string };
      pending: boolean;
    }
  | { kind: 'confirm-address'; address: string }
  | { kind: 'revoke-address'; address: string };

export type BackgroundResponse =
  | { ok: true; kind: 'auth-state'; signedIn: boolean }
  // `domain` is null when this install has not been told which deployment
  // to talk to: no stored value and no build default.
  | { ok: true; kind: 'control-domain'; domain: string | null }
  // `signedIn` is true when the flow completed inline (Chrome's identity
  // API); false when it is running in a tab and the background will finish
  // it out-of-band -- watch `storage.onChanged` for the session instead.
  | { ok: true; kind: 'sign-in-started'; signedIn: boolean }
  | { ok: true; kind: 'signed-out' }
  | { ok: true; kind: 'domains'; domains: Domain[] }
  | { ok: true; kind: 'addresses'; addresses: Address[] }
  | { ok: true; kind: 'address-created'; address: string }
  | { ok: true; kind: 'address-confirmed' }
  | { ok: true; kind: 'address-revoked' }
  // `message` is a sentence for people; `status` is the API's, when there was one.
  | { ok: false; error: BackgroundError; message: string; status?: number };

export type BackgroundError =
  | 'no-control-domain'
  | 'not-signed-in'
  | 'session-expired'
  | 'network'
  | 'api'
  // The API refused the request (409): `/new` for an address that is
  // already in use, with a sentence that says so.
  | 'refused'
  | 'bad-request';

/**
 * An `ok: false` answer, thrown on the content and popup side of the bridge
 * with its kind intact, so a caller can tell a refusal from an outage
 * without reading the sentence.
 */
export class BackgroundCallError extends Error {
  constructor(
    public readonly kind: BackgroundError,
    message: string,
    public readonly status?: number,
  ) {
    super(message);
    this.name = 'BackgroundCallError';
  }
}

/** Did the API refuse the request, rather than fail to answer it? */
export function isRefusal(err: unknown): boolean {
  return err instanceof BackgroundCallError && err.kind === 'refused';
}

/** The sentence to show for a failure: never empty, never a class name. */
export function failureMessage(err: unknown): string {
  const text = err instanceof Error ? err.message : String(err ?? '');
  return text.trim() !== '' ? text : 'Something went wrong, and the extension could not say what.';
}

/** Type guard used on the background side of the bridge. */
export function isBackgroundRequest(value: unknown): value is BackgroundRequest {
  return (
    typeof value === 'object' &&
    value !== null &&
    'kind' in value &&
    typeof (value as { kind: unknown }).kind === 'string'
  );
}

/**
 * Popup -> content-script messages, sent with `tabs.sendMessage` to the
 * active tab. The content script already runs on every https page, so it can
 * answer for the page without the popup holding any tab permission of its
 * own; a tab it is not injected into (browser-internal pages, tabs opened
 * before install) simply does not answer, and the popup carries on without.
 */
export type PageRequest = { kind: 'get-page-hostname' };

export type PageResponse = { kind: 'page-hostname'; hostname: string };

export function isPageRequest(value: unknown): value is PageRequest {
  return (
    typeof value === 'object' &&
    value !== null &&
    (value as { kind: unknown }).kind === 'get-page-hostname'
  );
}

export function isPageResponse(value: unknown): value is PageResponse {
  return (
    typeof value === 'object' &&
    value !== null &&
    (value as { kind: unknown }).kind === 'page-hostname' &&
    typeof (value as { hostname: unknown }).hostname === 'string'
  );
}
