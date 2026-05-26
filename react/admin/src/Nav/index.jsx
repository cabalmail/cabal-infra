import { useCallback, useEffect, useRef, useState } from 'react';
import { Search, Check, PanelLeft, ExternalLink } from 'lucide-react';
import logoMarkup from '../assets/logo.svg?raw';
import './Nav.css';

const NAV_VIEWS = [
  { id: 'email',     name: 'Email',     label: 'Email',     requiresAdmin: false },
  { id: 'addresses', name: 'Addresses', label: 'Addresses', requiresAdmin: true  },
  { id: 'users',     name: 'Users',     label: 'Users',     requiresAdmin: true  },
  { id: 'dmarc',     name: 'DMARC',     label: 'DMARC',     requiresAdmin: true  },
  { id: 'about',     name: 'About',     label: 'About',     requiresAdmin: false },
];

// Monitoring tools live on sibling subdomains behind the ALB's Cognito-auth
// action, not inside the React app. Open in a new tab; each first visit per
// 12h session runs through the existing Hosted-UI redirect.
const MONITORING_LINKS = [
  { id: 'uptime',    label: 'Uptime Kuma',  subdomain: 'uptime'    },
  { id: 'heartbeat', label: 'Healthchecks', subdomain: 'heartbeat' },
  { id: 'metrics',   label: 'Grafana',      subdomain: 'metrics'   },
];

function initialsFor(name) {
  if (!name) return '?';
  const clean = String(name).trim();
  if (!clean) return '?';
  const parts = clean.split(/[\s._-]+/).filter(Boolean);
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

function Nav({
  loggedIn,
  onClick,
  view,
  doLogout,
  isAdmin,
  userName,
  accent,
  onSelectAccent,
  accents,
  searchQuery = '',
  onSearchSubmit,
  controlDomain = null,
  monitoring = false,
}) {
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef(null);
  // The input is uncommitted: the user types here, but Enter is what hands
  // the value over to App.jsx via `onSearchSubmit`. `searchQuery` is the
  // committed value the rest of the app reads; this local mirror keeps the
  // input in sync when search is cleared from elsewhere (e.g. picking a
  // folder in the Email view, or clicking Clear in the search header).
  const [searchInput, setSearchInput] = useState(searchQuery);
  useEffect(() => { setSearchInput(searchQuery); }, [searchQuery]);

  const submitSearch = useCallback((e) => {
    e.preventDefault();
    if (typeof onSearchSubmit !== 'function') return;
    onSearchSubmit((searchInput || '').trim());
  }, [onSearchSubmit, searchInput]);

  const handleSearchKey = useCallback((e) => {
    if (e.key === 'Escape' && searchInput) {
      e.preventDefault();
      setSearchInput('');
      if (typeof onSearchSubmit === 'function') onSearchSubmit('');
    }
  }, [searchInput, onSearchSubmit]);

  useEffect(() => {
    if (!menuOpen) return undefined;
    const onDocClick = (e) => {
      if (menuRef.current && !menuRef.current.contains(e.target)) {
        setMenuOpen(false);
      }
    };
    const onKey = (e) => { if (e.key === 'Escape') setMenuOpen(false); };
    document.addEventListener('mousedown', onDocClick);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDocClick);
      document.removeEventListener('keydown', onKey);
    };
  }, [menuOpen]);

  const handleItemClick = useCallback((e) => {
    setMenuOpen(false);
    onClick(e);
  }, [onClick]);

  const handleLogout = useCallback((e) => {
    setMenuOpen(false);
    doLogout(e);
  }, [doLogout]);

  const visibleViews = NAV_VIEWS.filter((v) => !v.requiresAdmin || isAdmin);
  const showMonitoring = isAdmin && monitoring && !!controlDomain;

  const openDrawer = useCallback(() => {
    // Email listens for this event and toggles its folder drawer. Using a
    // window event avoids lifting drawer state into App for a button that
    // only matters in one view.
    window.dispatchEvent(new CustomEvent('cabal:toggle-nav-drawer'));
  }, []);

  return (
    <header
      className={`nav logged-${loggedIn ? 'in' : 'out'}${isAdmin ? ' is-admin' : ''}`}
    >
      <div className="nav__left">
        <div className="nav__brand">
          <span
            className="nav__brand-tile"
            aria-hidden="true"
            dangerouslySetInnerHTML={{ __html: logoMarkup }}
          />
          <span className="nav__brand-word">Cabalmail</span>
        </div>
        {loggedIn && (
          <button
            type="button"
            className={`nav__sidebar-toggle${view === 'Email' ? '' : ' nav__sidebar-toggle--hidden'}`}
            aria-label="Open sidebar"
            onClick={openDrawer}
          >
            <PanelLeft size={18} aria-hidden="true" />
          </button>
        )}
      </div>

      {loggedIn && (
        <form className="nav__search" onSubmit={submitSearch} role="search">
          <Search className="nav__search-icon" size={14} aria-hidden="true" />
          <input
            type="search"
            className="nav__search-input"
            placeholder="Search mail, senders, attachments…"
            aria-label="Search mail"
            value={searchInput}
            onChange={(e) => setSearchInput(e.target.value)}
            onKeyDown={handleSearchKey}
          />
          <kbd className="nav__search-kbd" aria-hidden="true">⌘K</kbd>
        </form>
      )}

      <div className="nav__right">
        {loggedIn ? (
          <div className="nav__menu-wrap" ref={menuRef}>
            <button
              type="button"
              className="nav__avatar"
              aria-label="Account menu"
              aria-haspopup="menu"
              aria-expanded={menuOpen}
              onClick={() => setMenuOpen((o) => !o)}
            >
              {initialsFor(userName)}
            </button>
            {menuOpen && (
              <div className="nav__menu" role="menu">
                {userName && (
                  <div className="nav__menu-head">
                    <div className="nav__menu-avatar" aria-hidden="true">{initialsFor(userName)}</div>
                    <div className="nav__menu-who">
                      <div className="nav__menu-name">{userName}</div>
                    </div>
                  </div>
                )}

                <div className="nav__menu-section-label">Accent</div>
                <div className="nav__menu-accents" role="group" aria-label="Accent color">
                  {accents.map((c) => (
                    <button
                      key={c}
                      type="button"
                      className={`nav__accent-swatch${c === accent ? ' is-active' : ''}`}
                      data-accent={c}
                      aria-label={`Accent ${c}`}
                      aria-pressed={c === accent}
                      onClick={() => onSelectAccent(c)}
                    >
                      {c === accent && <Check size={12} aria-hidden="true" />}
                    </button>
                  ))}
                </div>

                <div className="nav__menu-sep" role="separator" />

                {visibleViews.map((v) => (
                  <button
                    key={v.id}
                    type="button"
                    id={v.id}
                    role="menuitem"
                    name={v.name}
                    className={`nav__menu-item${view === v.name ? ' is-active' : ''}`}
                    onClick={handleItemClick}
                  >
                    {v.label}
                  </button>
                ))}

                {showMonitoring && (
                  <>
                    <div className="nav__menu-sep" role="separator" />
                    <div className="nav__menu-section-label">Monitoring</div>
                    {MONITORING_LINKS.map((link) => (
                      <a
                        key={link.id}
                        id={link.id}
                        role="menuitem"
                        href={`https://${link.subdomain}.${controlDomain}/`}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="nav__menu-item nav__menu-item--external"
                        onClick={() => setMenuOpen(false)}
                      >
                        <span className="nav__menu-item-label">{link.label}</span>
                        <ExternalLink size={12} aria-hidden="true" />
                      </a>
                    ))}
                  </>
                )}

                <div className="nav__menu-sep" role="separator" />

                <button
                  type="button"
                  id="logout"
                  role="menuitem"
                  name="LogOut"
                  className="nav__menu-item nav__menu-item--danger"
                  onClick={handleLogout}
                >
                  Log out
                </button>
              </div>
            )}
          </div>
        ) : (
          <>
            <button
              type="button"
              id="login"
              name="Login"
              className={`nav__text-btn${view === 'Login' ? ' is-active' : ''}`}
              onClick={handleItemClick}
            >
              Log in
            </button>
            <button
              type="button"
              id="signup"
              name="SignUp"
              className={`nav__text-btn nav__text-btn--primary${view === 'SignUp' ? ' is-active' : ''}`}
              onClick={handleItemClick}
            >
              Sign up
            </button>
          </>
        )}
      </div>
    </header>
  );
}

export default Nav;
