import React from 'react';
import './Nav.css'

class Nav extends React.Component {
  render() {
    const { loggedIn, onClick, view } = this.props;
    console.log(loggedIn);
    return (
      <div className={`nav logged-${loggedIn ? 'in' : 'out'}`}>
        <a
          id="list"
          className={`item${view === "List" ? " active" : ""}`}
          name="List"
          onClick={onClick}
          href="#list"
        >List Addresses</a>
        <a
          id="request"
          className={`item${view === "Request" ? " active" : ""}`}
          name="Request"
          onClick={onClick}
          href="#request"
        >New Address</a>
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
        <a
          id="logout"
          className="item"
          name="LogOut"
          onClick={onClick}
          href="#login"
        >Log out</a>
      </div>
    );
  }
}

export default Nav;