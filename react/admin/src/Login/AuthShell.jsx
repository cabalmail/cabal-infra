import logoSvg from '../assets/logo.svg';
import './AuthShell.css';

/**
 * Shared chrome for Login / SignUp / ForgotPassword per §§1–3:
 * wordmark header, centered card body, terms / privacy / status footer.
 */
export default function AuthShell({ headerRight, children, cardSize = 'default' }) {
  const cardClass = cardSize === 'narrow'
    ? 'auth__card auth__card--narrow'
    : cardSize === 'wide'
      ? 'auth__card auth__card--wide'
      : 'auth__card';
  return (
    <div className="auth">
      <header className="auth__header">
        <span className="auth__brand" aria-label="Cabalmail">
          <span className="auth__brand-tile" aria-hidden="true">
            <img className="auth__brand-logo" src={logoSvg} alt="" />
          </span>
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
          <a href="#">Terms</a>
          <a href="#">Privacy</a>
          <a href="#">Status</a>
        </div>
        <div className="auth__footer-right">Cabalmail</div>
      </footer>
    </div>
  );
}
