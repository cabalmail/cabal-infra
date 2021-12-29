import React from 'react';
import Address from './Address';

class AddressList extends React.Component {

  renderAddresses(addresses) {
    return addresses.map(a => <Address address={a.address} />);
  }

  render() {
    return (
      <div>
        {this.renderAddresses(this.props.addresses)}
      </div>
    );
  }

}

export default AddressList;