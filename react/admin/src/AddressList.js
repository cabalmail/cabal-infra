import React from 'react';
import Address from './Address';

class AddressList extends React.Component {

  render() {
    const addresses = this.props.addresses.map(a => <Address address={a.address} />);
    return (
      <ul className="address-list">
        {addresses}
      </ul>
    );
  }

}

export default AddressList;