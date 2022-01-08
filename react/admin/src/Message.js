import React from 'react';
import './Message.css';

class Message extends React.Component {

  render() {
    const hide = this.props.hide ? "hidden" : "visible"
    return (
      <div className={`message ${hide}`}>{this.props.message}</div>
    );
  }

}

export default Message;