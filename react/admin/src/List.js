import React from 'react';
import axios from 'axios';
import AddressList from './AddressList';

class List extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      filter: "",
      addresses: []
    };
    const response = this.getList();
    response.then(data => {
      this.setState({ addresses: data.data.Items });
    });
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
    )});
  }

  componentDidMount() {
    const response = this.getList();
    response.then(data => {
      this.setState({ addresses: data.data.Items });
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

  handleSubmit = (e) => {
    e.preventDefault();
  }

  getList = async (e) => {
    const response = await axios.get('/list', {
      baseURL: this.props.api_url,
      headers: {
        'Authorization': this.props.token
      },
      timeout: 1000
    }).catch( (err) => {
      if (err.response) {
        console.log("Error in response while retrieving address list", err.response);
      } else if (err.request) {
        console.log("Error with request while retrieving address list", err.request);
      } else {
        console.log("Unknown error while retrieving address list", err);
      }
    });
    return response;
  }

  updateFilter = (e) => {
    e.preventDefault();
    this.setState({filter: e.target.value});
  }

  render() {
    return (
      <div className="list">
        <form className="list-form" onSubmit={this.handleSubmit}>
        <input
          type="text"
          value={this.state.filter}
          onChange={this.updateFilter}
          id="filter"
          name="filter"
        />
        </form>
        <div id="count">Found: {this.state.addresses.length} addresses</div>
        <div id="list">
          <AddressList
            addresses={this.state.addresses}
          />
        </div>
      </div>
    );
  }

}

export default List;