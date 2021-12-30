import React from 'react';
import './Nav.css'

class Nav extends React.Component {
  render() {
    const { loggedIn, onClick, view } = this.props;
    console.log(loggedIn);
    return (
      <div className={`ui pointing menu nav logged-${loggedIn ? 'in' : 'out'}`}>
        <a
          id="list"
          className={`item${view === "List" ? " selected" : ""}`}
          name="List"
          onClick={onClick}
        >List Addresses</a>
        <a
          id="request"
          className={`item${view === "Request" ? " selected" : ""}`}
          name="Request"
          onClick={onClick}
        >New Address</a>
        <a
          id="login"
          className={`item${view === "Login" ? " selected" : ""}`}
          name="Login"
          onClick={onClick}
        >Log in</a>
        <a
          id="signup"
          className={`item${view === "SignUp" ? " selected" : ""}`}
          name="SignUp"
          onClick={onClick}
        >Sign up</a>
        <a id="logout" className="item" name="LogOut" onClick={onClick}>Log out</a>
      </div>
    );
  }
}

export default Nav;