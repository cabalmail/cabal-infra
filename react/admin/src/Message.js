import React from 'react';
import './Message.css';

class Message extends React.Component {

  render() {
    if (this.props.message) {
      return (
        <div className="message visible">{this.props.message}</div>
      );
    }
    return (
      <div className="message hidden"></div>
    );
  }

}

export default Message;