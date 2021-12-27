import React from 'react';

class Nav extends React.Component {
  render() {
    return (
      <div className="nav">
        <ul className="nav">
          <li><button name="list" onClick={this.props.onClick}>List Addresses</button></li>
          <li><button name="request" onClick={this.props.onClick}>New Address</button></li>
          <li><button name="logoug" onClick={this.props.onClick}>Log out</button></li>
        </ul>
      </div>
    );
  }
}

export default Nav;