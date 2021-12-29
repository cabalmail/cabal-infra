import React from 'react';

class Address extends React.Component {
  render() {
    return (
      <li className="address">{this.props.address}</li>
    );
  }
}

export default Address;