import React from 'react';
import './Message.css';

class Message extends React.Component {

  render() {
    return (
      <div className="message">{this.props.message}</div>
    );
  }

}

function setMessageHook(message) {
  console.log(message);
}

export { Message, setMessageHook };