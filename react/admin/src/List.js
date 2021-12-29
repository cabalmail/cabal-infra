import React from 'react';
import axios from 'axios';
import AddressList from './AddressList';
// TODO: move this to a configuration file
const invokeUrl = 'https://osg06j8v6e.execute-api.us-east-1.amazonaws.com/prod';

class List extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      filter: "",
      addresses: []
    };
  }

  componentDidMount() {
    this.getList();
  }

  getList = async (e) => {
    e.preventDefault();
    const response = await axios.get('/list', {
      baseURL: invokeUrl,
      headers: {
        'Authorization': this.props.token
      },
      timeout: 1000
    }).catch( (err) => {
      if (err.response) {
        console.log("Error in response");
        console.log(err.response);
      } else if (err.request) {
        console.log("Error with request");
        console.log(err.request);
      } else {
        console.log("Unknown error");
        console.log(err);
      }
    });
    if (response) {
      this.setState({ addresses: response.data.Items.filter(
        (a) => {
          if (a.address.includes(this.state.filter)) {
            return true;
          }
          if (a.comment.includes(this.state.filter)) {
            return true;
          }
          return false;
        }
      ) });
    } else {
      console.log("No response received");
    }
  }

  updateFilter = (e) => {
    e.preventDefault();
    this.setState({filter: e.target.value});
  }

  render() {
    return (
      <div className="list">
        <h1>List</h1>
        <form className="list-form" onSubmit={this.getList}>
        <input
          type="text"
          value={this.state.filter}
          onChange={this.updateFilter}
          id="filter"
          name="filter"
        />
        <button type="submit">Submit</button>
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