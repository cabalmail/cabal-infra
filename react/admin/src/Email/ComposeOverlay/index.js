import React from 'react';

class ComposeOverlay extends React.Component {

  handleSubmit = (e) => {
    e.preventDefault();
    return false;
  }

  handleSend = (e) => {
    e.preventDefault();
    return false;
  }

  handleCancel = (e) => {
    e.preventDefault();
    // TODO: clear all inputs
    this.props.hide();
  }

  render() {
    return (
      <form className="compose-overlay" onSubmit={this.handleSubmit}>
        <fieldset>
          <legend>Envelope</legend>
          <input type="radio" value="old" id="address-select-old" name="address-select/>
          <label for="address-select-old">Use an existing address</label>
          <input type="radio" value="new" id="address-select-old" name="address-select/>
          <label for="address-select-new">Use an existing address</label>
          <label for="address-to">To</legend>
          <input type="text" id="address-to" name="address-to"/>
          <label for="address-cc">CC</legend>
          <input type="text" id="address-cc" name="address-cc"/>
          <label for="address-bcc">BCC</legend>
          <input type="text" id="address-bcc" name="address-cc"/>
          <label for="subject">Subject</legend>
          <input type="text" id="subject" name="subject"/>
        </fieldset>
        <fieldset>
          <legend>Message</legend>
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