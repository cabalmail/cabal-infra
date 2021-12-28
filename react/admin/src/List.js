import React from 'react';
import axios from 'axios';
// TODO: move this to a configuration file
const invokeUrl = 'https://osg06j8v6e.execute-api.us-east-1.amazonaws.com/prod';

class List extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      filter: ""
    };
  }

  getList() {
    axios.get(invokeUrl + '/list', {
      headers: {
        Authorization: this.props.token
      }
    });
    //console.log(response);
  }

  handleSubmit = (e) => {
    e.preventDefault();
    console.log({f: "handleSubmit", e: e});
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
        <div id="list"></div>
      </div>
    );
  }

}

export default List;