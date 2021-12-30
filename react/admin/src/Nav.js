import React from 'react';
import './Nav.css'

class Nav extends React.Component {
  render() {
    const { loggedIn, onClick } = this.props;
    console.log(loggedIn);
    return (
      <div className={`ui pointing menu nav logged-${loggedIn ? 'in' : 'out'}`}>
        <ul className="nav">
          <li id="list" className={`item${this.props.view === "List" ? " selected" : ""}`}>
            <button name="List" onClick={onClick}>List Addresses</button>
          </li>
          <li id="request" className={`item${this.props.view === "Request" ? " selected" : ""}`}>
            <button name="Request" onClick={onClick}>New Address</button>
          </li>
          <li id="login" className={`item${this.props.view === "Login" ? " selected" : ""}`}>
            <button name="Login" onClick={onClick}>Log in</button>
          </li>
          <li id="signup" className={`item${this.props.view === "SignUp" ? " selected" : ""}`}>
            <button name="SignUp" onClick={onClick}>Sign up</button>
          </li>
            <li id="logout" className="item">
            <button name="LogOut" onClick={onClick}>Log out</button>
          </li>
        </ul>
      </div>
    );
  }
}

export default Nav;