/**
 * MV3 service worker: the auth boundary. Owns tokens, talks to the
 * Cabalmail API, answers typed messages from the content script and popup,
 * completes the tab-based sign-in flow, and brokers the private-link
 * handoff (Phase 7).
 */

import browser from 'webextension-polyfill';
import { ApiClient } from '@cabalmail/extension-shared/api/ApiClient';
import {
  AuthError,
  clearPendingFlow,
  HostedUiAuth,
} from '@cabalmail/extension-shared/auth/HostedUiAuth';
import { clearTokens, loadTokens } from '@cabalmail/extension-shared/auth/tokens';
import { authRedirectUri, defaultDriver } from '@cabalmail/extension-shared/auth/webAuthDriver';
import { ConfigService } from '@cabalmail/extension-shared/config/ConfigService';
import {
  isBackgroundRequest,
  type BackgroundRequest,
  type BackgroundResponse,
} from '@cabalmail/extension-shared/messaging/messages';
import type { Address, Domain } from '@cabalmail/extension-shared/models/index';

declare const __CONTROL_DOMAIN__: string;

const configService = new ConfigService(__CONTROL_DOMAIN__);

async function services(): Promise<{ auth: HostedUiAuth; api: ApiClient }> {
  const config = await configService.get();
  if (!config.extensionClientId || !config.authDomain) {
    throw new AuthError(
      'flow-failed',
      'This environment has no extension app client provisioned yet',
    );
  }
  const auth = new HostedUiAuth(
    {
      authDomain: config.authDomain,
      clientId: config.extensionClientId,
    },
    // identity API on Chrome; admin-origin tab flow on Safari, which has
    // no identity API at all (see webAuthDriver.ts).
    defaultDriver(__CONTROL_DOMAIN__),
  );
  return { auth, api: new ApiClient(config.apiUrl, auth) };
}

/** Short-lived caches so the adopt flow's per-keystroke checks stay local. */
const CACHE_TTL_MS = 30_000;
let domainsCache: { at: number; domains: string[] } | null = null;
let addressesCache: { at: number; addresses: Address[] } | null = null;

function invalidateAddresses(): void {
  addressesCache = null;
}

async function handle(request: BackgroundRequest): Promise<BackgroundResponse> {
  // Auth-state and sign-out read/clear local token storage only; keep them
  // independent of the config fetch so the popup can render a sensible
  // signed-out state even when the control domain is unreachable (or a dev
  // build was made without CABALMAIL_CONTROL_DOMAIN).
  if (request.kind === 'get-auth-state') {
    return { ok: true, kind: 'auth-state', signedIn: (await loadTokens()) !== null };
  }
  if (request.kind === 'sign-out') {
    await clearPendingFlow();
    await clearTokens();
    return { ok: true, kind: 'signed-out' };
  }
  const { auth, api } = await services();
  switch (request.kind) {
    case 'sign-in': {
      const signedIn = await auth.signIn();
      return { ok: true, kind: 'sign-in-started', signedIn };
    }
    case 'list-domains': {
      if (!domainsCache || Date.now() - domainsCache.at > CACHE_TTL_MS) {
        domainsCache = { at: Date.now(), domains: await api.listMyDomains() };
      }
      const domains: Domain[] = domainsCache.domains.map((d) => ({ domain: d }));
      return { ok: true, kind: 'domains', domains };
    }
    case 'list-addresses': {
      if (!addressesCache || Date.now() - addressesCache.at > CACHE_TTL_MS) {
        addressesCache = { at: Date.now(), addresses: await api.listAddresses() };
      }
      return { ok: true, kind: 'addresses', addresses: addressesCache.addresses };
    }
    case 'create-address': {
      const address = await api.newAddress({
        username: request.address.username,
        subdomain: request.address.subdomain,
        tld: request.address.tld,
        comment: request.address.comment,
        pending: request.pending,
      });
      invalidateAddresses();
      return { ok: true, kind: 'address-created', address };
    }
    case 'confirm-address':
      await api.confirmAddress(request.address);
      invalidateAddresses();
      return { ok: true, kind: 'address-confirmed' };
    case 'revoke-address':
      await api.revokeAddress(request.address);
      invalidateAddresses();
      return { ok: true, kind: 'address-revoked' };
  }
}

browser.runtime.onMessage.addListener(async (message: unknown): Promise<BackgroundResponse> => {
  if (!isBackgroundRequest(message)) {
    return { ok: false, error: 'bad-request', message: 'unrecognized message' };
  }
  try {
    return await handle(message);
  } catch (err) {
    if (err instanceof AuthError) {
      const error =
        err.reason === 'session-expired'
          ? 'session-expired'
          : err.reason === 'not-signed-in'
            ? 'not-signed-in'
            : 'api';
      return { ok: false, error, message: err.message };
    }
    return { ok: false, error: 'api', message: String(err) };
  }
});

// ── Tab-flow sign-in completion (Safari) ───────────────────────────────────
// Safari has no identity API, so its Hosted UI flow runs in an ordinary tab
// that redirects to https://admin.<control-domain>/extension-auth. The
// popup that started it is long gone by then, so completion has to be an
// event, not the tail of a promise.

const AUTH_REDIRECT_PREFIX = authRedirectUri(__CONTROL_DOMAIN__);
/** Guards against onUpdated firing twice for the same navigation. */
const completingTabs = new Set<number>();

function completeSignIn(tabId: number, url: string): void {
  if (completingTabs.has(tabId)) return;
  completingTabs.add(tabId);
  void (async () => {
    try {
      const { auth } = await services();
      await auth.completeSignIn(url);
      await browser.tabs.remove(tabId);
    } catch (err) {
      // Leave the tab open on failure: /extension-auth explains itself, and
      // a vanished tab would be one more silent failure.
      console.warn('[cabalmail] sign-in completion failed:', err);
    } finally {
      completingTabs.delete(tabId);
    }
  })();
}

// ── Private-link handoff (Phase 7) ──────────────────────────────────────────
// The mail clients open https://admin.<control-domain>/private-link#<target>;
// we intercept the navigation, validate the target, re-open it in a private
// window, close the redirector tab, and scrub the history entry. Fragments
// never reach the server, so the target is never logged upstream.

const REDIRECTOR_PREFIX = `https://admin.${__CONTROL_DOMAIN__}/private-link`;
const BLOCKED_SCHEMES = /^\s*(javascript|data|file|about|blob|vbscript):/i;

export function extractPrivateLinkTarget(url: string): string | null {
  if (!url.startsWith(REDIRECTOR_PREFIX)) return null;
  const hash = new URL(url).hash.slice(1);
  if (!hash) return null;
  let target: string;
  try {
    target = decodeURIComponent(hash);
  } catch {
    target = hash;
  }
  if (!/^https?:\/\//i.test(target) || BLOCKED_SCHEMES.test(target)) return null;
  return target;
}

// tabs.onUpdated rather than webNavigation.onCommitted: it needs no extra
// permission (the URL is visible to us because the redirector lives under
// our admin host permission, and tabs.remove is permission-free), which
// keeps the store-listing permission surface to storage/identity/history.
// The same listener catches the tab flow's OAuth redirect (see
// webAuthDriver.ts): both targets live on the admin origin, and both must
// be caught by a top-level listener, since the worker may have been
// suspended between opening the tab and the redirect landing.
browser.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (!changeInfo.url) return;
  const url = changeInfo.url;
  if (url.startsWith(AUTH_REDIRECT_PREFIX)) {
    completeSignIn(tabId, url);
    return;
  }
  const target = extractPrivateLinkTarget(url);
  if (!target) return;
  void (async () => {
    try {
      await browser.windows.create({ incognito: true, url: target });
      await browser.tabs.remove(tabId);
      await browser.history?.deleteUrl({ url });
    } catch (err) {
      // Most likely: the user has not granted private-browsing access. The
      // redirector tab is left in place, and its own page explains the
      // "Allow in Private Browsing"/"Allow in Incognito" setup with an
      // "Open normally" escape hatch -- so the failure is visible, not
      // silent. Log for debuggability.
      console.warn('[cabalmail] private-window open failed:', err);
    }
  })();
});
