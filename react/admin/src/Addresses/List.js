import React from 'react';
import ApiClient from '../ApiClient';

/**
 * Fetches addresses for current user and displays them
 */

class List extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      filter: "",
      addresses: []
    };
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  filter(data) {
    this.setState({ ...this.state, addresses: data.Items.filter(
      (a) => {
        return [a.address, a.comment].join('.')
          .toLowerCase()
          .includes(this.state.filter.toLowerCase());
      }
    ).sort(
      (a,b) => {
        if (a.address > b.address) {
          return 1;
        } else if (a.address < b.address) {
          return -1;
        }
        return 0;
      }
    )});
  }

  componentDidMount() {
    const response = this.getList();
    response.then(data => {
      localStorage.setItem("address_list", JSON.stringify(data));
      this.setState({ ...this.state, addresses: data.data.Items.sort(
        (a,b) => {
          if (a.address > b.address) {
            return 1;
          } else if (a.address < b.address) {
            return -1;
          }
          return 0;
        }
      ) });
    });
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.state.filter !== prevState.filter) {
      const response = this.getList();
      response.then(data => {
        localStorage.setItem("address_list", JSON.stringify(data));
        this.filter(data.data);
      });
    }
  }

  revokeAddress = (a) => {
    return this.api.deleteAddress(a.address, a.subdomain, a.tld, a.public_key);
  }

  revoke = (e) => {
    e.preventDefault();
    const address = e.target.value;
    this.revokeAddress(this.state.addresses.find(a => {
      return a.address === address;
    })).then(data => {
      this.props.setMessage("Successfully revoked address.", false);
      this.setState({...this.state, addresses: this.state.addresses.filter(a => {
        return a.address !== address;
      })});
    }, reason => {
      this.props.setMessage("Request to revoke address failed.", true);
      console.error("Promise rejected", reason);
    });
  }

  copy = (e) => {
    e.preventDefault();
    const address = e.target.value;
    navigator.clipboard.writeText(address);
    this.props.setMessage(`The address ${address} has been copied to your clipboard.`, false);
  }

  reload = (e) => {
    e.preventDefault();
    const response = this.getList();
    response.then(data => {
      localStorage.setItem("address_list", JSON.stringify(data));
      this.filter(data.data);
    });
  }

  handleSubmit = (e) => {
    e.preventDefault();
  }

  getList = (e) => {
    return this.api.getAddresses();
  }

  updateFilter = (e) => {
    e.preventDefault();
    this.setState({...this.state, filter: e.target.value});
  }

  render() {
    const addressList = this.state.addresses.map(a => {
      return (
        <li key={a.address} className="address">
          <span>{a.address.replace(/([.@])/g, "$&\u200B")}</span>
          <span>{a.comment}</span>
          <button
            onClick={this.copy}
            value={a.address}
            title="Copy this address"
          >📋</button>
          <button
            onClick={this.revoke}
            value={a.address}
            title="Revoke this address"
          >🗑️</button>
        </li>
      )
    });
    return (
      <div className="list">
        <form className="list-form" onSubmit={this.handleSubmit}>
        <input
          type="text"
          value={this.state.filter}
          onChange={this.updateFilter}
          id="filter"
          name="filter"
          placeholder="filter"
        /><button id="reload" onClick={this.reload} title="Reload addresses">⟳</button>
        </form>
        <div id="count">Found: {this.state.addresses.length} addresses</div>
        <div id="list">
          <ul className="address-list">
            {addressList}
          </ul>
        </div>
      </div>
    );
  }

}

export default List;