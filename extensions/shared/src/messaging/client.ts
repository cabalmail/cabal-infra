/** Content-script / popup side of the background bridge. */

import browser from 'webextension-polyfill';
import type { BackgroundPort } from '../content/controller';
import type { BackgroundRequest, BackgroundResponse } from './messages';

export async function sendToBackground(request: BackgroundRequest): Promise<BackgroundResponse> {
  return (await browser.runtime.sendMessage(request)) as BackgroundResponse;
}

function unwrap<K extends Extract<BackgroundResponse, { ok: true }>['kind']>(
  response: BackgroundResponse,
  kind: K,
): Extract<BackgroundResponse, { ok: true; kind: K }> {
  if (!response.ok) throw new Error(`${response.error}: ${response.message}`);
  if (response.kind !== kind) throw new Error(`unexpected response ${response.kind}`);
  return response as Extract<BackgroundResponse, { ok: true; kind: K }>;
}

/** The real BackgroundPort used by the content script. */
export function runtimeBackgroundPort(): BackgroundPort {
  return {
    async isSignedIn() {
      const r = await sendToBackground({ kind: 'get-auth-state' });
      return r.ok && r.kind === 'auth-state' ? r.signedIn : false;
    },
    async listDomains() {
      const r = unwrap(await sendToBackground({ kind: 'list-domains' }), 'domains');
      return r.domains.map((d) => d.domain);
    },
    async listAddresses() {
      const r = unwrap(await sendToBackground({ kind: 'list-addresses' }), 'addresses');
      return r.addresses.map((a) => a.address);
    },
    async createAddress(req) {
      unwrap(
        await sendToBackground({
          kind: 'create-address',
          address: {
            username: req.username,
            subdomain: req.subdomain,
            tld: req.tld,
            comment: req.comment,
          },
          pending: req.pending,
        }),
        'address-created',
      );
    },
    async confirmAddress(address) {
      unwrap(await sendToBackground({ kind: 'confirm-address', address }), 'address-confirmed');
    },
    async revokeAddress(address) {
      unwrap(await sendToBackground({ kind: 'revoke-address', address }), 'address-revoked');
    },
  };
}
