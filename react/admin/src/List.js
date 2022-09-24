import React from 'react';
import axios from 'axios';
import './List.css';

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
  }

  filter(data) {
    this.setState({ addresses: data.Items.filter(
      (a) => {
        if (a.address.includes(this.state.filter)) {
          return true;
        }
        if (a.comment.includes(this.state.filter)) {
          return true;
        }
        return false;
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
      this.setState({ addresses: data.data.Items.sort(
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
        this.filter(data.data);
      });
    }
  }

  revokeAddress = async (a) => {
    const response = await axios.delete('/revoke', {
      baseURL: this.props.api_url,
      data: JSON.stringify({
        address: a.address,
        subdomain: a.subdomain,
        tld: a.tld,
        public_key: a.public_key
      }),
      headers: {
        'Authorization': this.props.token
      },
      timeout: 10000
    });
    return response;
  }

  revoke = (e) => {
    e.preventDefault();
    const address = e.target.value;
    this.revokeAddress(this.state.addresses.find(a => {
      return a.address === address;
    })).then(data => {
      this.props.setMessage("Successfully revoked address.");
      this.setState({addresses: this.state.addresses.filter(a => {
        return a.address !== address;
      })});
    }, reason => {
      this.props.setMessage("Request failed.");
      console.error("Promise rejected", reason);
    });
  }

  copy = (e) => {
    e.preventDefault();
    const address = e.target.value;
    navigator.clipboard.writeText(address);
    this.props.setMessage(`The address ${address} has been copied to your clipboard.`);
  }

  reload = (e) => {
    e.preventDefault();
    const response = this.getList();
    response.then(data => {
      this.filter(data.data);
    });
  }

  handleSubmit = (e) => {
    e.preventDefault();
  }

  getList = async (e) => {
    const response = await axios.get('/list', {
      baseURL: this.props.api_url,
      headers: {
        'Authorization': this.props.token
      },
      timeout: 10000
    });
    return response;
  }

  updateFilter = (e) => {
    e.preventDefault();
    this.setState({filter: e.target.value});
  }

  render() {
    const addressList = this.state.addresses.map(a => {
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
      <div className="list">
        <form className="list-form" onSubmit={this.handleSubmit}>
        <input
          type="text"
          value={this.state.filter}
          onChange={this.updateFilter}
          id="filter"
          name="filter"
          placeholder="filter"
        /><button id="reload" onClick={this.reload}>⟳</button>
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