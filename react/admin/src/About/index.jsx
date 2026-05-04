import { useEffect, useState } from 'react';
import './About.css';

const REPO_URL = 'https://github.com/cabalmail/cabal-infra';

function useFetchedText(url) {
  const [text, setText] = useState(null);
  const [error, setError] = useState(null);
  useEffect(() => {
    let cancelled = false;
    fetch(url)
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.text();
      })
      .then((t) => { if (!cancelled) setText(t); })
      .catch((e) => { if (!cancelled) setError(e.message); });
    return () => { cancelled = true; };
  }, [url]);
  return { text, error };
}

function About({ loggedIn, onBackToLogin }) {
  const license = useFetchedText('/LICENSE.md');
  const notices = useFetchedText('/third-party-notices.txt');

  return (
    <div className="about">
      <header className="about__header">
        <h1 className="about__title">About Cabalmail</h1>
        <p className="about__subtitle">
          Self-hosted email, run on your own AWS account. The full source
          code is published at{' '}
          <a href={REPO_URL} target="_blank" rel="noopener noreferrer">
            {REPO_URL.replace('https://', '')}
          </a>.
        </p>
        {!loggedIn && onBackToLogin ? (
          <p className="about__back">
            <a href="#" onClick={onBackToLogin}>Back to sign in</a>
          </p>
        ) : null}
      </header>

      <section className="about__section">
        <h2 className="about__h2">License</h2>
        <p>
          Cabalmail is licensed under the{' '}
          <a
            href="https://www.gnu.org/licenses/agpl-3.0.html"
            target="_blank"
            rel="noopener noreferrer"
          >
            GNU Affero General Public License, version 3
          </a>{' '}
          (AGPL-3.0). The native client applications under the{' '}
          <code>apple/</code> directory of the source tree are licensed
          separately under the{' '}
          <a
            href="https://www.apache.org/licenses/LICENSE-2.0"
            target="_blank"
            rel="noopener noreferrer"
          >
            Apache License, version 2.0
          </a>{' '}
          (Apache-2.0). The Apache-2.0 carve-out exists because GPL-family
          licenses are incompatible with the Apple App Store and similar
          app distribution platforms.
        </p>
        <details className="about__details">
          <summary>View full LICENSE</summary>
          {license.text ? (
            <pre className="about__pre">{license.text}</pre>
          ) : license.error ? (
            <p className="about__error">
              Could not load LICENSE.md ({license.error}). The full text is
              available in the repository at{' '}
              <a href={`${REPO_URL}/blob/main/LICENSE.md`} target="_blank" rel="noopener noreferrer">
                LICENSE.md
              </a>.
            </p>
          ) : (
            <p className="about__loading">Loading license text...</p>
          )}
        </details>
      </section>

      <section className="about__section">
        <h2 className="about__h2">Third-party notices</h2>
        <p>
          The Cabalmail web client bundles open-source software from third
          parties. Their copyright notices and license texts are reproduced
          below in fulfillment of those licenses' attribution requirements.
        </p>
        <details className="about__details">
          <summary>View bundled-dependency notices</summary>
          {notices.text ? (
            <pre className="about__pre">{notices.text}</pre>
          ) : notices.error ? (
            <p className="about__error">
              Notices file is not available ({notices.error}). It is
              generated at build time by{' '}
              <code>rollup-plugin-license</code>; in a development build it
              may not be present. Run <code>npm run build</code> in{' '}
              <code>react/admin/</code> to produce it.
            </p>
          ) : (
            <p className="about__loading">Loading notices...</p>
          )}
        </details>
      </section>
    </div>
  );
}

export default About;
