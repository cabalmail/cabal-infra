import './Nav.css';

function Nav({ loggedIn, onClick, view, doLogout, isAdmin }) {
  return (
    <div className={`nav logged-${loggedIn ? 'in' : 'out'}${isAdmin ? ' is-admin' : ''}`}>
      <div className="logo">
        <img src="/mask.png" alt="Cabalmail logo" />
      </div>
      <button
        id="email"
        className={`item${view === "Email" ? " active" : ""}`}
        name="Email"
        onClick={onClick}
      >Email</button>
      <button
        id="folders"
        className={`item${view === "Folders" ? " active" : ""}`}
        name="Folders"
        onClick={onClick}
      >Folders</button>
      <button
        id="addresses"
        className={`item${view === "Addresses" ? " active" : ""}`}
        name="Addresses"
        onClick={onClick}
      >Addresses</button>
      <button
        id="users"
        className={`item${view === "Users" ? " active" : ""}`}
        name="Users"
        onClick={onClick}
      >Users</button>
      <button
        id="dmarc"
        className={`item${view === "DMARC" ? " active" : ""}`}
        name="DMARC"
        onClick={onClick}
      >DMARC</button>
      <button
        id="login"
        className={`item${view === "Login" ? " active" : ""}`}
        name="Login"
        onClick={onClick}
      >Log in</button>
      <button
        id="signup"
        className={`item${view === "SignUp" ? " active" : ""}`}
        name="SignUp"
        onClick={onClick}
      >Sign up</button>
      <button
        id="logout"
        className="item"
        name="LogOut"
        onClick={doLogout}
      >Log out</button>
    </div>
  );
}

export default Nav;
