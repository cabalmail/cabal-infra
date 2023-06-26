import React from 'react';
import './ComposeOverlay.css';
import Composer from './Composer';

class ComposeOverlay extends React.Component {

  handleSubmit = (e) => {
    e.preventDefault();
    return false;
  }

  handleSend = (e) => {
    e.preventDefault();
    const markdown = this.state.editor.getMarkdown();
    console.log(markdown);
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
        <fieldset>
          <legend>Envelope</legend>
          <input type="radio" value="old" id="address-select-old" name="address-select" />
          <label for="address-select-old">Use an existing address</label>
          <input type="radio" value="new" id="address-select-old" name="address-select" />
          <label for="address-select-new">Use an existing address</label>
          <label for="address-to">To</label>
          <input type="text" id="address-to" name="address-to" />
          <label for="address-cc">CC</label>
          <input type="text" id="address-cc" name="address-cc" />
          <label for="address-bcc">BCC</label>
          <input type="text" id="address-bcc" name="address-cc" />
          <label for="subject">Subject</label>
          <input type="text" id="subject" name="subject" />
        </fieldset>
        <fieldset>
          <legend>Message</legend>
          <div id="container">
            <Composer editorState={this.state.editorState} onChange={this.onMessageChange} />
          </div>
        </fieldset>
        <fieldset>
          <button onClick={this.handleSend}>Send</button>
          <button onClick={this.handleCancel}>Cancel</button>
        </fieldset>
      </form>
    );
  }
}

export default ComposeOverlay;