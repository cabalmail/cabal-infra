import React from 'react';
import axios from 'axios';
// TODO: move this to a configuration file
const invokeUrl = 'https://osg06j8v6e.execute-api.us-east-1.amazonaws.com/prod';

class List extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      filter: "",
      addresses: []
    };
    this.getList();
  }

  async getList() {
    const response = await axios.get(invokeUrl + '/list', {
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
      this.setState({ addresses: response.data.Items });
    } else {
      console.log("No response received");
    }
  }

  handleSubmit = (e) => {
    e.preventDefault();
    this.getList();
  }

  updateFilter = (e) => {
    e.preventDefault();
    this.setState({filter: e.target.value});
  }

  render() {
    return (
      <div className="list">
        <h1>List</h1>
        <form className="list-form" onSubmit={this.handleSubmit}>
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
        <div id="list"></div>
      </div>
    );
  }

}

export default List;