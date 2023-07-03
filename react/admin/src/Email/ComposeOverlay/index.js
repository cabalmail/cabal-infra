import React from 'react';
import './ComposeOverlay.css';
import Composer from './Composer';

class ComposeOverlay extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      editorState: null
    };
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

  render() {
    return (
      <form className="compose-overlay" onSubmit={this.handleSubmit}>
        <input type="radio" value="old" id="address-select-old" name="address-select" />
        <label htmlFor="address-select-old">Use an existing address</label>
        <input type="radio" value="new" id="address-select-old" name="address-select" />
        <label htmlFor="address-select-new">Create a new address</label>
        <label for="address-from">From</label>
        <input type="text" id="address-from" name="address-from" />
        <label for="address-to">To</label>
        <input type="text" id="address-to" name="address-to" />
        <label htmlFor="address-cc">CC</label>
        <input type="text" id="address-cc" name="address-cc" />
        <label htmlFor="address-bcc">BCC</label>
        <input type="text" id="address-bcc" name="address-cc" />
        <label htmlFor="subject">Subject</label>
        <input type="text" id="subject" name="subject" />
        <Composer editorState={this.state.editorState} onChange={this.onMessageChange} />
        <button onClick={this.handleSend} className="default">Send</button>
        <button onClick={this.handleCancel}>Cancel</button>
      </form>
    );
  }
}

export default ComposeOverlay;