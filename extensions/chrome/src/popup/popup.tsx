/** Toolbar popup: session state, authorized apex domains, escape hatches. */

import browser from 'webextension-polyfill';
import { render } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { TOKEN_KEY } from '@cabalmail/extension-shared/auth/tokens';
import { sendToBackground } from '@cabalmail/extension-shared/messaging/client';

declare const __CONTROL_DOMAIN__: string;
declare const __REPORT_URL__: string;

// Build-time (CABALMAIL_REPORT_URL) so forks point reports at their own
// tracker; defaults to the upstream cabal-infra issue template.
const REPORT_URL = __REPORT_URL__;

// The origins the background must reach to sign in and to serve the API.
// Chrome grants manifest host permissions at install; Safari grants them per
// site at the user's discretion, and a background fetch to an ungranted
// origin has no page to prompt on -- so ask for them here, in the click
// handler, where a permission prompt is allowed.
const HOST_ORIGINS = [`https://admin.${__CONTROL_DOMAIN__}/*`, 'https://*.amazoncognito.com/*'];

/**
 * Ask for the host permissions the flow needs. Returns null when the
 * browser gives no usable answer, in which case we proceed and let the
 * request itself report the failure. Must be the first await in a click
 * handler: Chrome rejects `permissions.request` outside a user gesture.
 */
async function requestHostAccess(): Promise<boolean | null> {
  const perms = browser.permissions as typeof browser.permissions | undefined;
  if (!perms) return null;
  try {
    return await perms.request({ origins: HOST_ORIGINS });
  } catch {
    try {
      return await perms.contains({ origins: HOST_ORIGINS });
    } catch {
      return null;
    }
  }
}

function Popup() {
  const [signedIn, setSignedIn] = useState<boolean | null>(null);
  const [domains, setDomains] = useState<string[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);

  // Raw fetch errors name nothing actionable; translate the common cases.
  // Never return something falsy: an empty error renders as no error at all.
  const friendly = (message: string | undefined): string =>
    !message
      ? 'The extension hit an error it could not describe. Check the extension console.'
      : /failed to fetch|timed out/i.test(message)
      ? `Can't reach https://admin.${__CONTROL_DOMAIN__}/ — check your network and that ` +
        `this extension is allowed to access that site, or rebuild with ` +
        `CABALMAIL_CONTROL_DOMAIN set if this is a dev build.`
      : message;

  const refresh = async () => {
    setError(null);
    const state = await sendToBackground({ kind: 'get-auth-state' });
    if (state.ok && state.kind === 'auth-state') {
      setSignedIn(state.signedIn);
      if (state.signedIn) {
        const result = await sendToBackground({ kind: 'list-domains' });
        if (result.ok && result.kind === 'domains') {
          setDomains(result.domains.map((d) => d.domain));
        } else if (!result.ok) {
          setError(friendly(result.message));
        }
      }
    } else if (!state.ok) {
      // Auth-state is local-only in the background; a failure here is
      // unexpected, but never leave the popup stuck on "Loading…".
      setSignedIn(false);
      setError(friendly(state.message));
    }
  };

  // Every handler funnels through this: an unhandled rejection in a click
  // handler is a button that visibly does nothing, which is the worst
  // failure mode a sign-in button can have.
  const guard = async (work: () => Promise<void>) => {
    try {
      await work();
    } catch (err) {
      setStatus(null);
      setError(friendly(err instanceof Error ? err.message : String(err)));
    }
  };

  useEffect(() => {
    void guard(refresh);
    // The tab-based flow (Safari) completes in the background long after the
    // click, so watch the session rather than waiting on the click's reply.
    const onChanged = (
      changes: Record<string, browser.Storage.StorageChange>,
      area: string,
    ) => {
      if (area === 'local' && TOKEN_KEY in changes) {
        setStatus(null);
        void guard(refresh);
      }
    };
    browser.storage.onChanged.addListener(onChanged);
    return () => browser.storage.onChanged.removeListener(onChanged);
  }, []);

  const signIn = () =>
    guard(async () => {
      setError(null);
      setStatus('Opening the Cabalmail sign-in page…');
      const granted = await requestHostAccess();
      if (granted === false) {
        setStatus(null);
        setError(
          `This extension needs permission to access admin.${__CONTROL_DOMAIN__} ` +
            `to sign in. Grant it in the browser's extension settings, then try again.`,
        );
        return;
      }
      const result = await sendToBackground({ kind: 'sign-in' });
      if (!result.ok) {
        setStatus(null);
        setError(friendly(result.message));
        return;
      }
      if (result.kind === 'sign-in-started' && !result.signedIn) {
        // Opening the sign-in tab usually closes this popup; the session
        // lands via storage.onChanged, whether or not anyone is watching.
        setStatus('Finish signing in on the tab that just opened.');
        return;
      }
      setStatus(null);
      await refresh();
    });

  const signOut = () =>
    guard(async () => {
      await sendToBackground({ kind: 'sign-out' });
      setSignedIn(false);
      setDomains(null);
      setStatus(null);
    });

  return (
    <div>
      <h1 style={{ fontSize: '16px', margin: '0 0 8px' }}>Cabalmail</h1>
      {signedIn === null && <p>Loading…</p>}
      {signedIn === false && (
        <div>
          <p>Sign in to suggest fresh Cabalmail addresses on sign-up forms.</p>
          <button onClick={signIn}>Sign in with Cabalmail</button>
        </div>
      )}
      {signedIn === true && (
        <div>
          {domains && domains.length > 0 && (
            <div>
              <p style={{ margin: '0 0 4px' }}>Your apex domains:</p>
              <ul style={{ margin: '0 0 8px' }}>
                {domains.map((d) => (
                  <li key={d}>{d}</li>
                ))}
              </ul>
            </div>
          )}
          {domains && domains.length === 0 && (
            <p>
              No apex domains are assigned to your account yet, so the
              extension can't suggest addresses. Domains are assigned in the{' '}
              <a href={`https://admin.${__CONTROL_DOMAIN__}/`} target="_blank" rel="noreferrer">
                admin app
              </a>
              .
            </p>
          )}
          <button onClick={signOut}>Sign out</button>
        </div>
      )}
      {status && <p style={{ color: 'var(--cm-muted)' }}>{status}</p>}
      {error && <p style={{ color: 'var(--cm-danger)' }}>{error}</p>}
      <hr />
      <p style={{ fontSize: '12px', color: 'var(--cm-muted)' }}>
        <a href={`https://admin.${__CONTROL_DOMAIN__}/`} target="_blank" rel="noreferrer">
          Manage addresses
        </a>
        {' · '}
        <a href={REPORT_URL} target="_blank" rel="noreferrer">
          Report wrong detection
        </a>
      </p>
    </div>
  );
}

render(<Popup />, document.getElementById('root') as HTMLElement);
