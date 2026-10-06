/**
 * The private-link handoff's fragment, and how it becomes a target URL.
 *
 * The mail clients open `https://admin.<control-domain>/private-link#<f>`
 * and the background re-opens the target in a private window. Two forms of
 * `<f>` exist, because the scrub that follows does not exist everywhere:
 *
 * - **The target itself**, percent-encoded. Chrome then removes the
 *   redirector entry with `history.deleteUrl`, so the target does not
 *   linger in normal-window history.
 * - **An opaque token**, 16 random bytes in hex, resolved over
 *   `sendNativeMessage` by the appex embedded in the macOS mail app. This
 *   is the Safari form (#1765): WebKit implements no `history` API at all
 *   -- the declared permission is dropped as unrecognised and
 *   `typeof browser.history` is `undefined` -- so the redirector entry
 *   cannot be removed there and must not be worth reading. A leftover
 *   entry then says a private window was opened and not what was opened.
 *
 * The app decides the form (`PrivateLinkHandoff.fragmentForm`); this side
 * accepts either. Resolution is deliberately separate from validation: the
 * scheme blocklist applies to the *resolved* URL, since a token's target
 * has not been through the redirector's address bar.
 */

import browser from 'webextension-polyfill';

export type PrivateLinkFragment =
  | { kind: 'url'; url: string }
  | { kind: 'token'; token: string };

/** The same policy the reader link menu and the redirector page apply. */
const BLOCKED_SCHEMES = /^\s*(javascript|data|file|about|blob|vbscript):/i;

/**
 * Token shape, kept in step with `PrivateLinkTokenStore.newToken()` in
 * apple/CabalmailUI/Platform/Services/PrivateLinkTokenStore.swift. Anchored and fixed-length so
 * no percent-encoded URL can be mistaken for one.
 */
export const PRIVATE_LINK_TOKEN = /^[0-9a-f]{32}$/;

export function privateLinkRedirector(controlDomain: string): string {
  return `https://admin.${controlDomain}/private-link`;
}

/** What the fragment of a redirector URL carries, or null if neither. */
export function parsePrivateLinkFragment(
  url: string,
  controlDomain: string,
): PrivateLinkFragment | null {
  if (!url.startsWith(privateLinkRedirector(controlDomain))) return null;
  let hash: string;
  try {
    hash = new URL(url).hash.slice(1);
  } catch {
    return null;
  }
  if (!hash) return null;
  if (PRIVATE_LINK_TOKEN.test(hash)) return { kind: 'token', token: hash };
  let decoded: string;
  try {
    decoded = decodeURIComponent(hash);
  } catch {
    decoded = hash;
  }
  return { kind: 'url', url: decoded };
}

/** `target` if it is a plain web URL, else null. */
export function allowedPrivateLinkTarget(target: string): string | null {
  if (!/^https?:\/\//i.test(target) || BLOCKED_SCHEMES.test(target)) return null;
  return target;
}

type NativeRuntime = {
  sendNativeMessage?: (app: string, message: unknown) => Promise<unknown>;
};

/**
 * Ask the containing mail app what a token resolves to. Null whenever
 * there is no host (Chrome, the standalone Safari host) or the row has
 * expired -- the redirector tab is then left in place and its own page
 * explains the setup, which is the existing failure behaviour.
 */
export async function resolvePrivateLinkToken(token: string): Promise<string | null> {
  try {
    const runtime = browser.runtime as NativeRuntime;
    if (!runtime.sendNativeMessage) return null;
    // Safari ignores the application id and routes to the containing app.
    const reply = (await runtime.sendNativeMessage('application.id', {
      kind: 'resolve-private-link',
      token,
    })) as { url?: unknown } | null;
    return reply && typeof reply.url === 'string' ? reply.url : null;
  } catch {
    return null;
  }
}

/**
 * Retire a resolved token once its window is open. Best-effort: the rows
 * expire on their own, so a failure here costs nothing.
 */
export async function forgetPrivateLinkToken(token: string): Promise<void> {
  try {
    const runtime = browser.runtime as NativeRuntime;
    await runtime.sendNativeMessage?.('application.id', {
      kind: 'forget-private-link',
      token,
    });
  } catch {
    // Nothing to do: the row's TTL is the backstop.
  }
}

/**
 * The validated target behind a redirector URL, plus the token to retire
 * after opening it. Null when this is not a redirector URL, when the
 * fragment resolves to nothing, or when the target is not a web link.
 */
export async function privateLinkTarget(
  url: string,
  controlDomain: string,
): Promise<{ target: string; token: string | null } | null> {
  const fragment = parsePrivateLinkFragment(url, controlDomain);
  if (!fragment) return null;
  if (fragment.kind === 'url') {
    const target = allowedPrivateLinkTarget(fragment.url);
    return target ? { target, token: null } : null;
  }
  const resolved = await resolvePrivateLinkToken(fragment.token);
  if (!resolved) return null;
  const target = allowedPrivateLinkTarget(resolved);
  return target ? { target, token: fragment.token } : null;
}
