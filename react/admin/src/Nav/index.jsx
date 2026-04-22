import { useCallback, useEffect, useRef, useState } from 'react';
import { Search, Check, Menu } from 'lucide-react';
import logoMarkup from '../assets/logo.svg?raw';
import './Nav.css';

const NAV_VIEWS = [
  { id: 'email',     name: 'Email',     label: 'Email',     requiresAdmin: false },
  { id: 'addresses', name: 'Addresses', label: 'Addresses', requiresAdmin: true  },
  { id: 'users',     name: 'Users',     label: 'Users',     requiresAdmin: true  },
  { id: 'dmarc',     name: 'DMARC',     label: 'DMARC',     requiresAdmin: true  },
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
}) {
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef(null);

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
        {loggedIn && (
          <button
            type="button"
            className="nav__hamburger"
            aria-label="Open navigation"
            onClick={openDrawer}
          >
            <Menu size={18} aria-hidden="true" />
          </button>
        )}
        <div className="nav__brand">
          <span
            className="nav__brand-tile"
            aria-hidden="true"
            dangerouslySetInnerHTML={{ __html: logoMarkup }}
          />
          <span className="nav__brand-word">Cabalmail</span>
        </div>
      </div>

      {loggedIn && (
        <div className="nav__search">
          <Search className="nav__search-icon" size={14} aria-hidden="true" />
          <input
            type="search"
            className="nav__search-input"
            placeholder="Search mail, senders, attachments…"
            aria-label="Search mail"
          />
          <kbd className="nav__search-kbd" aria-hidden="true">⌘K</kbd>
        </div>
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
