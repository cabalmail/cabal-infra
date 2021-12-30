import React from 'react';
import './Request.css';

class Request extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      username: '',
      subdomain: '',
      comment: ''
    }
  }

  submitRequest = async (e) => {
    // TODO: wire up to API
    return false;
  }

  doInputChange = e => {
    e.preventDefault();
    this.setState({[e.target.name]: e.target.value});
  }

  render() {
    return (
      <div className="request">
        <form className="request-form" onSubmit={this.submitRequest}>
        <fieldset className="address-fields">
          <legend>Address</legend>
          <input
            type="text"
            value={this.state.username}
            onChange={this.doInputChange}
            id="username"
            name="username"
            placeholder="username"
          /><span id="amphora">@</span><input
            type="text"
            value={this.state.subdomain}
            onChange={this.doInputChange}
            id="subdomain"
            name="subdomain"
            placeholder="subdomain"
          />
        </fieldset>
        <fieldset className="comment-field">
          <legend>Comment</legend>
          <input
            type="text"
            value={this.state.comment}
            onChange={this.doInputChange}
            id="comment"
            name="comment"
            placeholder="comment"
          />
        </fieldset>
        <button type="submit" className="default">Submit</button>
        </form>
      </div>
    );
  }
}

export default Request;