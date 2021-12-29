import React from 'react';

class Address extends React.Component {
  render() {
    return (
      <div class="address">{this.props.address}</div>
    );
  }
}

export default Address;