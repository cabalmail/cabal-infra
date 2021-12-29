import React from 'react';
import 'Nav.css'

class Nav extends React.Component {
  render() {
    const { loggedIn, onClick } = this.props;
    return (
      <div className=`nav logged-${loggedIn ? 'in' : 'out'}`>
        <ul className="nav">
          <li id="list">
            <button name="List" onClick={onClick}>List Addresses</button>
          </li>
          <li id="request">
            <button name="Request" onClick={onClick}>New Address</button>
          </li>
          <li id="login">
            <button name="Login" onClick={onClick}>Log in</button>
          </li>
          <li id="signup">
            <button name="SignUp" onClick={onClick}>Sign up</button>
          </li>
            <li id="logout">
            <button name="LogOut" onClick={onClick}>Log out</button>
          </li>
        </ul>
      </div>
    );
  }
}

export default Nav;