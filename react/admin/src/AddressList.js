import React from 'react';
import './AddressList.css';

class AddressList extends React.Component {

  copy = (e) => {
    e.preventDefault();
    const address = e.target.value;
    navigator.clipboard.writeText(address);
    this.props.setMessage(`The address ${address} has been copied to your clipboard.`);
  }

  render() {
    const addresses = this.props.addresses.map(a => {
      return (
        <li key={a.address} className="address">
          <span>{a.address}</span>
          <span>{a.comment}</span>
          <button onClick={this.copy} value={a.address}>📋</button>
          <button onClick={this.props.revoke} value={a.address}>❌</button>
        </li>
      )
    });
    return (
      <ul className="address-list">
        {addresses}
      </ul>
    );
  }

}

export default AddressList;