import React from 'react';
import ApiClient from '../ApiClient';

/**
 * Renders a form for requesting a new address and handles
 * calling the request API
 */

class Request extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      username: '',
      subdomain: '',
      domain: '',
      comment: '',
      address: ''
    }
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  componentDidUpdate(prevProps, prevState) {
    if (
      prevState.username !== this.state.username ||
      prevState.subdomain !== this.state.subdomain ||
      prevState.domain !== this.state.domain
    ) {
      if (
        this.state.username === "" ||
        this.state.subdomain === "" ||
        this.state.domain === ""
      ) {
        this.setState({...this.state, address: ""});
      } else {
        this.setState({...this.state, address:`${this.state.username}@${this.state.subdomain}.${this.state.domain}`});
      }
    }
  }

  randomString(length, pool1, pool2, pool3) {
    let string = '';
    const pool1Size = pool1.length;
    const pool2Size = pool2.length;
    const pool3Size = pool3.length;
    for ( var i = 0; i < length; i++ ) {
      switch (i) {
        case 0:
          string += pool1.charAt(Math.floor(Math.random() *  pool1Size));
          break;
        case (length-1):
          string += pool3.charAt(Math.floor(Math.random() *  pool3Size));
          break;
        default:
          string += pool2.charAt(Math.floor(Math.random() *  pool2Size));
      }
    }
    return string;
  }

  generateRandom = (e) => {
    e.preventDefault();
    const domainLength = this.props.domains.length;
    const alphanum = 'abcdefghijklmnopqrstuvwxyz1234567890';
    this.setState({
      ...this.state,
      username: this.randomString(8, alphanum, alphanum+'._-', alphanum),
      subdomain: this.randomString(8, alphanum, alphanum+'-', alphanum),
      domain: this.props.domains[Math.floor(Math.random() *  domainLength)].domain
    });
  }

  doInputChange = e => {
    e.preventDefault();
    this.setState({...this.state, [e.target.name]: e.target.value});
  }

  getOptions() {
    return this.props.domains.map(d => {
      return (
        <option value={d.domain} key={d.domain}>
          {d.domain}
        </option>
      );
    });
  }

  submitRequest = (e) => {
    return this.api.newAddress(
      this.state.username,
      this.state.subdomain,
      this.state.domain,
      this.state.comment,
      this.state.username + '@' + this.state.subdomain + '.' + this.state.domain
    );
  }

  handleSubmit = (e) => {
    e.preventDefault();
    this.submitRequest().then(data => {
      this.props.setMessage(`Successfully requested ${data.data.address}.`, false);
    }, reason => {
      this.props.setMessage("Request failed.", true);
      console.error("Promise rejected", reason.toJSON());
    });
  }

  doClear = (e) => {
    e.preventDefault();
    this.setState({
      ...this.state,
      username: "",
      subdomain: "",
      domain: "",
      comment: "",
      address: ""
    });
  }

  render() {
    // TODO: Wire up select field for TLD
    return (
      <div className={`request ${this.props.showRequest ? "requestVisible" : "requestHidden"}`}>
        <form className="request-form" onSubmit={this.handleSubmit}>
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
          /><span id="dot">.</span><select
            name="domain"
            value={this.state.domain}
            onChange={this.doInputChange}
          >
            <option>Select a domain</option>
            {this.getOptions()}
          </select>
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
        <fieldset className="button-fields">
          <button id="request" type="submit" className="default">Request {this.state.address}</button>
          <button onClick={this.generateRandom}>Random</button>
          <button onClick={this.doClear}>Clear</button>
        </fieldset>
        </form>
      </div>
    );
  }
}

export default Request;