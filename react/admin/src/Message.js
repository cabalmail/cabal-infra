import React from 'react';
import './Message.css';

export default class Message extends React.Component {

  render() {
    return (
      <div className="message">{this.props.message}</div>
    );
  }

}

export function setMessageHook(message) {
  console.log(message);
}