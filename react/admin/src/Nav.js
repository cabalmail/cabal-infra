import React from 'react';

class Nav extends React.Component {
  render() {
    return (
      <div className="nav">
        <ul className="nav">
          <li><button name="List" onClick={this.props.onClick}>List Addresses</button></li>
          <li><button name="Request" onClick={this.props.onClick}>New Address</button></li>
          <li><button name="Login" onClick={this.props.onClick}>Log in</button></li>
          <li><button name="SignUp" onClick={this.props.onClick}>Sign up</button></li>
        </ul>
      </div>
    );
  }
}

export default Nav;