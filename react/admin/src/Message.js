import React from 'react';
import './Message.css';

class Message extends React.Component {

  setMessage(message) {
    console.log(message);
  }

  render() {
    return (
      <div className="message">{this.props.message}</div>
    );
  }

}

export default Message;