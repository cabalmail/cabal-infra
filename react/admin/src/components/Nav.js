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
          id="request"
          className={`item${view === "Request" ? " active" : ""}`}
          name="Request"
          onClick={onClick}
          href="#request"
        >New Address</a>
        <a
          id="list"
          className={`item${view === "List" ? " active" : ""}`}
          name="List"
          onClick={onClick}
          href="#list"
        >List Addresses</a>
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
        >Log out</button>
      </div>
    );
  }
}

export default Nav;