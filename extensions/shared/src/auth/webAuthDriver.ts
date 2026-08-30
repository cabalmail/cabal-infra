/**
 * The interactive leg of the Hosted UI flow, abstracted per browser.
 *
 * Chrome implements the WebExtensions `identity` API, so the flow rides
 * `launchWebAuthFlow` with the extension's `chromiumapp.org` redirect.
 * Safari implements no `identity` API at all (MDN compat:
 * `version_added: false`), so there the flow runs in a regular tab whose
 * redirect target is a page on the operator's own admin origin
 * (`/extension-auth`); the background watches for the redirect via
 * `tabs.onUpdated` — the same permission-free-for-our-host interception
 * the private-link handoff uses — then closes the tab. PKCE and the
 * `state` check keep the tab variant equivalent in security: the
 * authorization code is useless without the in-extension verifier.
 */

import browser from 'webextension-polyfill';

export interface WebAuthDriver {
  /** The redirect URI to register and to pass as `redirect_uri`. */
  redirectUri(): string;
  /** Run the interactive flow; resolve with the full redirect URL. */
  authorize(authorizeUrl: string): Promise<string>;
}

/** Give a signing-in user ample time; abandonments must not leak listeners. */
const TAB_FLOW_TIMEOUT_MS = 5 * 60 * 1000;

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
  remove(tabId: number): Promise<void>;
  onUpdated: {
    addListener(cb: (tabId: number, changeInfo: { url?: string }) => void): void;
    removeListener(cb: (tabId: number, changeInfo: { url?: string }) => void): void;
  };
  onRemoved: {
    addListener(cb: (tabId: number) => void): void;
    removeListener(cb: (tabId: number) => void): void;
  };
}

export function tabDriver(
  redirectUri: string,
  tabs: TabsLike = browser.tabs as unknown as TabsLike,
): WebAuthDriver {
  return {
    redirectUri: () => redirectUri,
    authorize: (authorizeUrl) =>
      new Promise<string>((resolve, reject) => {
        let authTabId: number | undefined;
        let timer: ReturnType<typeof setTimeout>;

        const cleanup = () => {
          clearTimeout(timer);
          tabs.onUpdated.removeListener(onUpdated);
          tabs.onRemoved.removeListener(onRemoved);
        };

        const onUpdated = (tabId: number, changeInfo: { url?: string }) => {
          if (tabId !== authTabId || !changeInfo.url) return;
          if (!changeInfo.url.startsWith(redirectUri)) return;
          cleanup();
          void tabs.remove(tabId).catch(() => {});
          resolve(changeInfo.url);
        };

        const onRemoved = (tabId: number) => {
          if (tabId !== authTabId) return;
          cleanup();
          reject(new Error('sign-in tab was closed'));
        };

        tabs.onUpdated.addListener(onUpdated);
        tabs.onRemoved.addListener(onRemoved);
        timer = setTimeout(() => {
          cleanup();
          if (authTabId !== undefined) void tabs.remove(authTabId).catch(() => {});
          reject(new Error('sign-in timed out'));
        }, TAB_FLOW_TIMEOUT_MS);

        tabs
          .create({ url: authorizeUrl })
          .then((tab) => {
            if (tab.id === undefined) {
              cleanup();
              reject(new Error('could not open a sign-in tab'));
              return;
            }
            authTabId = tab.id;
          })
          .catch((err: unknown) => {
            cleanup();
            reject(err instanceof Error ? err : new Error(String(err)));
          });
      }),
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
  return tabDriver(`https://admin.${controlDomain}/extension-auth`);
}
