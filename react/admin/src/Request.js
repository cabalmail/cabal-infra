import React from 'react';
import './Request.css';

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
  }

  submitRequest = async (e) => {
    // TODO: wire up to API
    return false;
  }

  componentDidUpdate(prevProps, prevState) {
    if (
      prevState.username !== this.state.username ||
      prevState.subdomain !== this.state.subdomain ||
      prevState.domain !== this.state.domain
    ) {
      this.setState({address:`${this.state.username}@${this.state.subdomain}.${this.state.domain}`});
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
        case length:
          string += pool3.charAt(Math.floor(Math.random() *  pool3Size));
          break;
        default:
          string += pool.charAt(Math.floor(Math.random() *  poolSize));
      }
    }
    return string;
  }

  generateRandom = (e) => {
    e.preventDefault();
    const domainLength = this.props.domains.length;
    const alphanum = 'abcdefghijklmnopqrstuvwxyz1234567890';
    this.setState({
      username: this.randomString(8, alphanum, alphanum+'_-', alphanum),
      subdomain: this.randomString(8, alphanum, alphanum+'-', alphanum),
      domain: this.props.domains[Math.floor(Math.random() *  domainLength)].domain
    });
  }

  doInputChange = e => {
    e.preventDefault();
    this.setState({[e.target.name]: e.target.value});
  }

  getOptions() {
    return this.props.domains.map(d => {
      return <option value={d.domain}>{d.domain}</option>;
    });
  }

  render() {
    // TODO: Wire up select field for TLD
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
          /><span id="dot">.</span><select
            value={this.state.domain}
            onChange={this.doInputChange}
          >
            <option>▼ Select a domain</option>
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
        <button type="submit" className="default">Request {this.state.address}</button>
        <button onClick={this.generateRandom}>Generate a random address</button>
        </form>
      </div>
    );
  }
}

export default Request;