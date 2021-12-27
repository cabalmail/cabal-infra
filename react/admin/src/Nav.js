import React from 'react';

class Nav extends React.Component {
  render() {
    return (
      <div className="nav">
        <ul className="nav">
          <li><a name="list">List Addresses</a></li>
          <li><a name="request">New Address</a></li>
          <li><a name="logoug">Log out</a></li>
        </ul>
      </div>
    );
  }
}

export default Nav;