import logoMarkup from '../assets/logo.svg?raw';
import { useAuth } from '../contexts/AuthContext';
import './AuthShell.css';

// Hardcoded. The project's status / changelog / runbook surface lives
// on the GitHub wiki, not on the front door site, so it doesn't follow
// the www.<control_domain> pattern of Terms / Privacy.
const STATUS_URL = 'https://github.com/cabalmail/cabal-infra/wiki';

/**
 * Shared chrome for Login / SignUp / ForgotPassword per sections 1-3:
 * wordmark header, centered card body, terms / privacy / status footer.
 */
export default function AuthShell({ headerRight, children, cardSize = 'default' }) {
  // control_domain is loaded asynchronously by App.jsx from /config.js
  // at mount. Pre-login screens are typically reached after that load
  // resolves, but for the brief window before it does, the legal links
  // fall back to "#" so we don't navigate to https://www.null/...
  const { control_domain } = useAuth();
  const frontDoorOrigin = control_domain ? `https://www.${control_domain}` : null;
  const termsHref = frontDoorOrigin ? `${frontDoorOrigin}/terms.html` : '#';
  const privacyHref = frontDoorOrigin ? `${frontDoorOrigin}/privacy.html` : '#';

  const cardClass = cardSize === 'narrow'
    ? 'auth__card auth__card--narrow'
    : cardSize === 'wide'
      ? 'auth__card auth__card--wide'
      : 'auth__card';
  return (
    <div className="auth">
      <header className="auth__header">
        <span className="auth__brand" aria-label="Cabalmail">
          <span
            className="auth__brand-tile"
            aria-hidden="true"
            dangerouslySetInnerHTML={{ __html: logoMarkup }}
          />
        </span>
        {headerRight ? <div className="auth__header-right">{headerRight}</div> : <span />}
      </header>
      <main className="auth__main">
        <div className={cardClass}>
          {children}
        </div>
      </main>
      <footer className="auth__footer">
        <div className="auth__footer-left">
          <a href={termsHref} target="_blank" rel="noopener noreferrer">Terms</a>
          <a href={privacyHref} target="_blank" rel="noopener noreferrer">Privacy</a>
          <a href={STATUS_URL} target="_blank" rel="noopener noreferrer">Status</a>
          <a
            href="#"
            onClick={(e) => {
              e.preventDefault();
              window.dispatchEvent(new CustomEvent('cabal:show-about'));
            }}
          >
            About
          </a>
        </div>
        <div className="auth__footer-right">Cabalmail</div>
      </footer>
    </div>
  );
}
