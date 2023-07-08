import React from 'react';
import './ComposeOverlay.css';
import ApiClient from '../../ApiClient';
import Composer from './Composer';
import { ADDRESS_LIST } from '../../constants';

class ComposeOverlay extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      editorState: null,
      showOldFrom: true,
      addresses: []
    };
    api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
    const response = api.getAddresses();
    response.then(data => {
      localStorage.setItem(ADDRESS_LIST, JSON.stringify(data));
      this.setState({addresses: data.Items
        .map(
          (a) => {
            return a.address;
          }
        )
        .sort(
          (a,b) => {
            if (a > b) {
              return 1;
            } else if (a < b) {
              return -1;
            }
            return 0;
          }
        )
      })
    });
  }

  getOptions() {
    return this.addresses.map((a) => {
      <option value={a}>{a}</option>
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
    this.setState({editorState});
  }

  onRadioChange = (e) => {
    this.setState({showOldFrom: !this.state.showOldFrom});
  }

  render() {
    const options = this.getOptions();
    return (
      <form className="compose-overlay" onSubmit={this.handleSubmit}>
        <div className={this.state.showOldFrom ? "compose-from-old" : "compose-from-new"}>
          <label className="radio">
            <input
              type="radio"
              value="old"
              id="address-select-old"
              name="address-select"
              checked={this.state.showOldFrom}
              onChange={this.onRadioChange}
            /><span className="radio-button"></span>Use an existing address</label>
          <label className="radio">
            <input
              type="radio"
              value="new"
              id="address-select-new"
              name="address-select"
              checked={!this.state.showOldFrom}
              onChange={this.onRadioChange}
            /><span className="radio-button"></span>Create a new address</label>
          <label for="address-from-old" className="address-from-old">From</label>
          <select
            type="text"
            id="address-from-old"
            name="address-from-old"
            className="address-from-old"
            placeholder="Find existing address"
          >{options}</select>
          <label for="address-from-new" className="address-from-new">From</label>
          <input
            type="text"
            id="address-from-new"
            name="address-from-new"
            className="address-from-new"
            placeholder="Enter new address"
          />
        </div>
        <label for="address-to">To</label>
        <input type="text" id="address-to" name="address-to" />
        <label htmlFor="address-cc">CC</label>
        <input type="text" id="address-cc" name="address-cc" />
        <label htmlFor="address-bcc">BCC</label>
        <input type="text" id="address-bcc" name="address-cc" />
        <label htmlFor="subject">Subject</label>
        <input type="text" id="subject" name="subject" />
        <Composer editorState={this.state.editorState} onChange={this.onMessageChange} />
        <button onClick={this.handleSend} className="default" id="compose-send">Send</button>
        <button onClick={this.handleCancel} id="compose-cancel">Cancel</button>
      </form>
    );
  }
}

export default ComposeOverlay;