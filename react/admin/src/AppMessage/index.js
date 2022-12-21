import React from 'react';
import './Message.css';

/**
 * Renders message box
 */

class Message extends React.Component {

  render() {
    const hide = this.props.hide ? "hidden" : "visible"
    return (
      <div className={`app-message ${hide}`}>{this.props.message}</div>
    );
  }

}

export default Message;