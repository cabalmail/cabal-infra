import React from 'react';
import Address from './Address';

class AddressList extends React.Component {

  render() {
    const addresses = this.props.addresses.map(a => <Address key={a.address} address={a.address} />);
    return (
      <ul className="address-list">
        {addresses}
      </ul>
    );
  }

}

export default AddressList;