import React from 'react';

class Nav extends React.Component {
  render() {
    return (
      <div className="nav">
        <ul className="nav">
          <li><a name="list" onClick={this.props.onClick}>List Addresses</a></li>
          <li><a name="request" onClick={this.props.onClick}>New Address</a></li>
          <li><a name="logoug" onClick={this.props.onClick}>Log out</a></li>
        </ul>
      </div>
    );
  }
}

export default Nav;