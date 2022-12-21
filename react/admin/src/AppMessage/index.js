import React from 'react';
import './AppMessage.css';

/**
 * Renders message box
 */

class Message extends React.Component {

  render() {
    const hide = this.props.hide ? "hidden" : "visible"
    const level = this.props.error ? "error" : "info"
    return (
      <div className={`app-message ${hide} ${level}`}>{this.props.message}</div>
    );
  }

}

export default Message;