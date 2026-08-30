/**
 * Content-script / popup <-> background message schema. The background
 * service worker is the auth boundary: it alone holds tokens and talks to
 * the Cabalmail API. Everything else asks via these messages.
 */

import type { Address, Domain } from '../models/index';

export type BackgroundRequest =
  | { kind: 'get-auth-state' }
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
  | { ok: true; kind: 'signed-in' }
  | { ok: true; kind: 'signed-out' }
  | { ok: true; kind: 'domains'; domains: Domain[] }
  | { ok: true; kind: 'addresses'; addresses: Address[] }
  | { ok: true; kind: 'address-created'; address: string }
  | { ok: true; kind: 'address-confirmed' }
  | { ok: true; kind: 'address-revoked' }
  | { ok: false; error: BackgroundError; message: string };

export type BackgroundError =
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
