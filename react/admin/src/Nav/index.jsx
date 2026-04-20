import { useState } from 'react';
import './Nav.css';

function Nav({ loggedIn, onClick, view, doLogout, isAdmin }) {
  const [menuOpen, setMenuOpen] = useState(false);

  const handleItemClick = (e) => {
    setMenuOpen(false);
    onClick(e);
  };

  const handleLogout = (e) => {
    setMenuOpen(false);
    doLogout(e);
  };

  return (
    <div className={`nav logged-${loggedIn ? 'in' : 'out'}${isAdmin ? ' is-admin' : ''}${menuOpen ? ' menu-open' : ''}`}>
      <div className="logo">
        <img src="/mask.png" alt="Cabalmail logo" />
      </div>
      <button
        id="hamburger"
        className="hamburger"
        aria-label="Menu"
        aria-expanded={menuOpen}
        onClick={() => setMenuOpen(o => !o)}
      >
        <span></span>
        <span></span>
        <span></span>
      </button>
      <div className="nav-items">
        <button
          id="email"
          className={`item${view === "Email" ? " active" : ""}`}
          name="Email"
          onClick={handleItemClick}
        >Email</button>
        <button
          id="folders"
          className={`item${view === "Folders" ? " active" : ""}`}
          name="Folders"
          onClick={handleItemClick}
        >Folders</button>
        <button
          id="addresses"
          className={`item${view === "Addresses" ? " active" : ""}`}
          name="Addresses"
          onClick={handleItemClick}
        >Addresses</button>
        <button
          id="users"
          className={`item${view === "Users" ? " active" : ""}`}
          name="Users"
          onClick={handleItemClick}
        >Users</button>
        <button
          id="dmarc"
          className={`item${view === "DMARC" ? " active" : ""}`}
          name="DMARC"
          onClick={handleItemClick}
        >DMARC</button>
        <button
          id="login"
          className={`item${view === "Login" ? " active" : ""}`}
          name="Login"
          onClick={handleItemClick}
        >Log in</button>
        <button
          id="signup"
          className={`item${view === "SignUp" ? " active" : ""}`}
          name="SignUp"
          onClick={handleItemClick}
        >Sign up</button>
        <button
          id="logout"
          className="item"
          name="LogOut"
          onClick={handleLogout}
        >Log out</button>
      </div>
    </div>
  );
}

export default Nav;
