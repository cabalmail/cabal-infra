/** Toolbar popup: session state, authorized apex domains, escape hatches. */

import { render } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { sendToBackground } from '@cabalmail/extension-shared/messaging/client';

declare const __CONTROL_DOMAIN__: string;

const REPORT_URL =
  'https://github.com/cabalmail/cabal-infra/issues/new?labels=needs-verification&title=Extension%3A%20wrong%20form%20detection';

function Popup() {
  const [signedIn, setSignedIn] = useState<boolean | null>(null);
  const [domains, setDomains] = useState<string[] | null>(null);
  const [error, setError] = useState<string | null>(null);

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
          setError(result.message);
        }
      }
    } else if (!state.ok) {
      setError(state.message);
    }
  };

  useEffect(() => {
    void refresh();
  }, []);

  const signIn = async () => {
    setError(null);
    const result = await sendToBackground({ kind: 'sign-in' });
    if (!result.ok) setError(result.message);
    await refresh();
  };

  const signOut = async () => {
    await sendToBackground({ kind: 'sign-out' });
    setSignedIn(false);
    setDomains(null);
  };

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
      {error && <p style={{ color: '#a00' }}>{error}</p>}
      <hr />
      <p style={{ fontSize: '12px', color: '#555' }}>
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
