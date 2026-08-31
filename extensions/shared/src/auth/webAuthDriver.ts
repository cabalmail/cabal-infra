/**
 * The interactive leg of the Hosted UI flow, abstracted per browser.
 *
 * Chrome implements the WebExtensions `identity` API, so the flow rides
 * `launchWebAuthFlow` with the extension's `chromiumapp.org` redirect, and
 * the driver itself observes the redirect: `authorize()` resolves with the
 * redirect URL.
 *
 * Safari implements no `identity` API at all (MDN compat:
 * `version_added: false`), so there the flow runs in an ordinary tab whose
 * redirect target is a page on the operator's own admin origin
 * (`/extension-auth`). That driver is deliberately *fire-and-forget*:
 * `authorize()` opens the tab and resolves `null`, and the redirect is
 * caught by the background's top-level `tabs.onUpdated` listener, which
 * calls `HostedUiAuth.completeSignIn`. Nothing may wait on a promise across
 * the interactive leg: opening the tab closes the popup that asked for
 * sign-in, and an MV3 background worker with no live caller is free to be
 * suspended -- an in-memory listener registered inside `authorize()` would
 * not survive to see the redirect. PKCE and the `state` check keep the tab
 * variant equivalent in security: the authorization code is useless without
 * the verifier, which lives in extension storage.
 */

import browser from 'webextension-polyfill';

export interface WebAuthDriver {
  /** The redirect URI to register and to pass as `redirect_uri`. */
  redirectUri(): string;
  /**
   * Run the interactive flow. Resolves with the full redirect URL when the
   * driver observes it itself, or `null` when the redirect arrives
   * out-of-band and the caller must wait for `completeSignIn`.
   */
  authorize(authorizeUrl: string): Promise<string | null>;
}

export function identityDriver(): WebAuthDriver {
  return {
    redirectUri: () => browser.identity.getRedirectURL(),
    authorize: async (authorizeUrl) => {
      const result = await browser.identity.launchWebAuthFlow({
        url: authorizeUrl,
        interactive: true,
      });
      if (!result) throw new Error('auth flow returned no redirect');
      return result;
    },
  };
}

/** Minimal surface of the tabs API the tab driver needs (injectable in tests). */
export interface TabsLike {
  create(props: { url: string }): Promise<{ id?: number }>;
}

export function tabDriver(
  redirectUri: string,
  tabs: TabsLike = browser.tabs as unknown as TabsLike,
): WebAuthDriver {
  return {
    redirectUri: () => redirectUri,
    authorize: async (authorizeUrl) => {
      await tabs.create({ url: authorizeUrl });
      return null;
    },
  };
}

/**
 * Pick the platform's driver: the identity API where it exists (Chrome),
 * the admin-origin tab flow where it doesn't (Safari).
 */
export function defaultDriver(controlDomain: string): WebAuthDriver {
  const identity = (browser as { identity?: { launchWebAuthFlow?: unknown } }).identity;
  if (identity && typeof identity.launchWebAuthFlow === 'function') {
    return identityDriver();
  }
  return tabDriver(authRedirectUri(controlDomain));
}

/** The tab flow's redirect target; also what the background watches for. */
export function authRedirectUri(controlDomain: string): string {
  return `https://admin.${controlDomain}/extension-auth`;
}
