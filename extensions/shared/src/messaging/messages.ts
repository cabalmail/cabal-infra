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
  | { kind: 'list-addresses' }
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
  | { ok: false; error: BackgroundError; message: string };

export type BackgroundError =
  | 'no-control-domain'
  | 'not-signed-in'
  | 'session-expired'
  | 'network'
  | 'api'
  | 'bad-request';

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
