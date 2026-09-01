/** Toolbar popup: server, session state, authorized apex domains, escape hatches. */

import browser from 'webextension-polyfill';
import { render } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { TOKEN_KEY } from '@cabalmail/extension-shared/auth/tokens';
import { requiredOrigins } from '@cabalmail/extension-shared/config/controlDomain';
import { sendToBackground } from '@cabalmail/extension-shared/messaging/client';

declare const __REPORT_URL__: string;

// Build-time (CABALMAIL_REPORT_URL) so forks point reports at their own
// tracker; defaults to the upstream cabal-infra issue template.
const REPORT_URL = __REPORT_URL__;

/**
 * Ask for the host permissions the flow needs, for the deployment this
 * install is pointed at. The origins are not known at build time any more,
 * so they are requested rather than declared: Chrome grants declared host
 * permissions at install, Safari grants them per site at the user's
 * discretion, and a background fetch to an ungranted origin has no page to
 * prompt on.
 *
 * Returns null when the browser gives no usable answer, in which case we
 * proceed and let the request itself report the failure. Must be the first
 * await in a click handler: Chrome rejects `permissions.request` outside a
 * user gesture.
 */
async function requestHostAccess(controlDomain: string): Promise<boolean | null> {
  const perms = browser.permissions as typeof browser.permissions | undefined;
  if (!perms) return null;
  const origins = requiredOrigins(controlDomain);
  try {
    return await perms.request({ origins });
  } catch {
    try {
      return await perms.contains({ origins });
    } catch {
      return null;
    }
  }
}

function Popup() {
  // undefined = still asking the background; null = not configured yet.
  const [domain, setDomain] = useState<string | null | undefined>(undefined);
  const [editingDomain, setEditingDomain] = useState(false);
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
        ? `Can't reach https://admin.${domain ?? ''}/ — check your network, that this ` +
          `extension is allowed to access that site, and that the server name is right.`
        : message;

  const refresh = async () => {
    setError(null);
    const configured = await sendToBackground({ kind: 'get-control-domain' });
    if (configured.ok && configured.kind === 'control-domain') {
      setDomain(configured.domain);
      if (configured.domain === null) {
        setSignedIn(null);
        return;
      }
    }
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

  const saveDomain = (event: Event) => {
    event.preventDefault();
    const value = new FormData(event.target as HTMLFormElement).get('domain');
    void guard(async () => {
      const result = await sendToBackground({
        kind: 'set-control-domain',
        domain: String(value ?? ''),
      });
      if (!result.ok) {
        setError(friendly(result.message));
        return;
      }
      setEditingDomain(false);
      await refresh();
    });
  };

  const signIn = () =>
    guard(async () => {
      if (!domain) return;
      setError(null);
      setStatus('Opening the Cabalmail sign-in page…');
      const granted = await requestHostAccess(domain);
      if (granted === false) {
        setStatus(null);
        setError(
          `This extension needs permission to access admin.${domain} to sign in. ` +
            `Grant it in the browser's extension settings, then try again.`,
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

  const domainForm = (
    <form onSubmit={saveDomain}>
      <p style={{ margin: '0 0 6px' }}>Which Cabalmail server should this extension use?</p>
      <input
        name="domain"
        placeholder="example.com"
        style={{ width: '100%', boxSizing: 'border-box', marginBottom: '6px' }}
        defaultValue={domain ?? ''}
      />
      <button type="submit">Use this server</button>
    </form>
  );

  return (
    <div>
      <h1 style={{ fontSize: '16px', margin: '0 0 8px' }}>Cabalmail</h1>
      {domain === undefined && <p>Loading…</p>}
      {domain !== undefined && (domain === null || editingDomain) && domainForm}
      {domain && !editingDomain && (
        <div>
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
                  No apex domains are assigned to your account yet, so the extension
                  can't suggest addresses. Domains are assigned in the{' '}
                  <a href={`https://admin.${domain}/`} target="_blank" rel="noreferrer">
                    admin app
                  </a>
                  .
                </p>
              )}
              <button onClick={signOut}>Sign out</button>
            </div>
          )}
        </div>
      )}
      {status && <p style={{ color: '#555' }}>{status}</p>}
      {error && <p style={{ color: '#a00' }}>{error}</p>}
      <hr />
      <p style={{ fontSize: '12px', color: '#555' }}>
        {domain && (
          <>
            <a href={`https://admin.${domain}/`} target="_blank" rel="noreferrer">
              Manage addresses
            </a>
            {' · '}
            <button
              onClick={() => setEditingDomain(true)}
              style={{
                background: 'none',
                border: 'none',
                padding: 0,
                font: 'inherit',
                color: '#06c',
                cursor: 'pointer',
              }}
            >
              Change server
            </button>
            {' · '}
          </>
        )}
        <a href={REPORT_URL} target="_blank" rel="noreferrer">
          Report wrong detection
        </a>
      </p>
    </div>
  );
}

render(<Popup />, document.getElementById('root') as HTMLElement);
