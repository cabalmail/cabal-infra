import React from 'react';
// import axios from 'axios';

class MessageOverlay extends React.Component {

  hide = (e) => {
    e.preventDefault();
    this.props.hide();
  }

  render() {
    console.log(JSON.stringify(this.props.envelope));
    if (this.props.visible) {
      return (
        <div className="message_overlay">
          <button onClick={this.hide} className="close_overlay">❌</button>
          <dl>
            <dt>To</dt>
            <dd>{this.props.envelope.to}</dd>
            <dt>From</dt>
            <dd>{this.props.envelope.from.join("; ")}</dd>
            <dt>Received</dt>
            <dd>{this.props.envelope.date}</dd>
            <dt>Subject</dt>
            <dd>{this.props.envelope.subject}</dd>
          </dl>
          <div className="body">Not implamented</div>
        </div>
      );
    }
    return <div className="message_overlay overlay_hidden"></div>;
  }
}

export default MessageOverlay;
