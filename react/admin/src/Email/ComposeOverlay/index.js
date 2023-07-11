import React from 'react';
import './ComposeOverlay.css';
import ApiClient from '../../ApiClient';
import Request from '../../Addresses/Request';
import Composer from './Composer';
import { ADDRESS_LIST } from '../../constants';
const STATE_KEY = 'compose-state';

class ComposeOverlay extends React.Component {

  constructor(props) {
    super(props);
    this.state = JSON.parse(localStorage.getItem(STATE_KEY)) || {
      editorState: null,
      showOldFrom: true,
      addresses: [],
      addressOld: "",
      addressNew: null,
      To: null,
      CC: null,
      BCC: null,
      Subject: null,
      showRequest: false
    };
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  setState(state) {
    try {
      localStorage.setItem(STATE_KEY, JSON.stringify(state));
    } catch (e) {
      console.log(e);
    }
    super.setState(state);
  }

  componentDidUpdate(prevProps, prevState) {
    if ((prevState.addresses.length !== this.state.address.length))
  }

  componentDidMount() {
    this.getAddresses();
  }

  getAddresses() {
    this.api.getAddresses().then(data => {
      try {
        localStorage.setItem(ADDRESS_LIST, JSON.stringify(data));
      } catch (e) {
        console.log(e);
      }
      this.setState({...this.state, addresses: data.data.Items.map(a => a.address).sort()});
    });
  }

  getOptions() {
    return this.state.addresses.map((a) => {
      return <option value={a}>{a}</option>;
    });
  }

  handleSubmit = (e) => {
    e.preventDefault();
    return false;
  }

  handleSend = (e) => {
    e.preventDefault();
    this.props.hide();
    return false;
  }

  handleCancel = (e) => {
    e.preventDefault();
    // TODO: clear all inputs
    this.props.hide();
  }

  onMessageChange = (editorState) => {
    this.setState({...this.state, editorState});
  }

  onRadioChange = (e) => {
    this.setState({...this.state, showOldFrom: !this.state.showOldFrom});
  }

  onSelectChange = (e) => {
    this.setState({...this.state, addressOld: e.target.value});
  }

  onAddressNewChange = (e) => {
    this.setState({...this.state, addressNew: e.target.value});
  }

  onToChange = (e) => {
    this.setState({...this.state, To: e.target.value});
  }

  onCcChange = (e) => {
    this.setState({...this.state, CC: e.target.value});
  }

  onBccChange = (e) => {
    this.setState({...this.state, BCC: e.target.value});
  }

  onSubjectChange = (e) => {
    this.setState({...this.state, Subject: e.target.value});
  }

  toggleRequest = () => {
    this.setState({...this.state, showRequest: !this.state.showRequest})
  }

  requestCallback(address) {
    this.setState({
      ...this.state,
      addresses:[...this.state.addresses, address],
      addressOld: address,
      showRequest: false
    });
  }

  render() {
    return (
      <form className="compose-overlay" onSubmit={this.handleSubmit}>
        <div className="compose-from-old">
          <label for="address-from-old" className="address-from-old">From</label>
          <select
            type="text"
            id="address-from-old"
            name="address-from-old"
            className="address-from-old"
            placeholder="Find existing address"
            onChange={this.onSelectChange}
            value={this.state.addressOld}
          ><option value="">Select an address</option>{this.getOptions()}</select>
          <button
            onClick={this.toggleRequest}
            className="toggleRequest"
          >New Address {this.state.showRequest ? "∨" : ">"}</button>
          <Request
            token={this.props.token}
            domains={this.props.domains}
            api_url={this.props.api_url}
            setMessage={this.props.setMessage}
            showRequest={this.state.showRequest}
            host={this.props.host}
            callback={this.requestCallback}
          />
        </div>
        <label for="address-to">To</label>
        <input
          type="email"
          id="address-to"
          name="address-to"
          onChange={this.onToChange}
          value={this.state.To}
        />
        <label htmlFor="address-cc">CC</label>
        <input
          type="email"
          id="address-cc"
          name="address-cc"
          onChange={this.onCcChange}
          value={this.state.CC}
        />
        <label htmlFor="address-bcc">BCC</label>
        <input
          type="email"
          id="address-bcc"
          name="address-cc"
          onChange={this.onBccChange}
          value={this.state.BCC}
        />
        <label htmlFor="subject">Subject</label>
        <input
          type="text"
          id="subject"
          name="subject"
          onChange={this.onSubjectChange}
          value={this.state.Subject}
        />
        <Composer editorState={this.state.editorState} onChange={this.onMessageChange} />
        <button onClick={this.handleSend} className="default" id="compose-send">Send</button>
        <button onClick={this.handleCancel} id="compose-cancel">Cancel</button>
      </form>
    );
  }
}

export default ComposeOverlay;