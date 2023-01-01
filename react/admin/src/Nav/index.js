import React from 'react';
import './Nav.css'

/**
 * Renders the navigation bar
 */

class Nav extends React.Component {
  render() {
    const { loggedIn, onClick, view } = this.props;
    return (
      <div className={`nav logged-${loggedIn ? 'in' : 'out'}`}>
        <div className="logo">
          <img src="/mask.png" alt="Cabalmail logo" />
        </div>
        <a
          id="email"
          className={`item${view === "Email" ? " active" : ""}`}
          name = "Email"
          onClick={onClick}
          href="#email"
          >Email</a>
        <a
          id="folders"
          className={`item${view === "Folders" ? " active" : ""}`}
          name="Folders"
          onClick={onClick}
          href="#folders"
        >Folders</a>
        <a
          id="addresses"
          className={`item${view === "Addresses" ? " active" : ""}`}
          name="Addresses"
          onClick={onClick}
          href="#addresses"
        >Addresses</a>
        <a
          id="login"
          className={`item${view === "Login" ? " active" : ""}`}
          name="Login"
          onClick={onClick}
          href="#login"
        >Log in</a>
        <a
          id="signup"
          className={`item${view === "SignUp" ? " active" : ""}`}
          name="SignUp"
          onClick={onClick}
          href="#signup"
        >Sign up</a>
        <button
          id="logout"
          className="item"
          name="LogOut"
          onClick={this.props.doLogout}
          href="#login"
        >Log out {this.props.countdown}</button>
      </div>
    );
  }
}

export default Nav;