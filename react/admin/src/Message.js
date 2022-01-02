import React from 'react';
import './Message.css';

class Message extends React.Component {
  render() {
    return (
      <div className="message">{this.props.message}</div>
    );
  }
}

export default Message;