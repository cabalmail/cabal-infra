import React from 'react';
import './AddressList.css';

class AddressList extends React.Component {

  copy = (e) => {
    e.preventDefault();
    const address = e.target.value;
    navigator.clipboard.writeText(address);
    this.props.setMessage(`The address ${address} has been copied to your clipboard.`);
  }

  revokeAddress = async (e) => {
    const response = await axios.delete('/revoke', {
      baseURL: this.props.api_url,
      body: JSON.stringify({
        address: a.address,
        subdomain: a.subdomain,
        tld: a.tld
      }),
      headers: {
        'Authorization': this.props.token
      },
      timeout: 1000
    });
    return response;
  }

  revoke = (e) => {
    e.preventDefault();
    this.revokeAddress().then(data => {
      this.props.setMessage("Successfully revoked address.");
    }, reason => {
      console.error("Promise rejected", reason);
      this.props.setMessage("The server failed to respond.");
    });
  }

  render() {
    const addresses = this.props.addresses.map(a => {
      return (
        <li key={a.address} className="address">
          <span>{a.address}</span>
          <span>{a.comment}</span>
          <button onClick={this.copy} value={a.address}>📋</button>
          <button onClick={this.revoke} value={a.address}>❌</button>
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