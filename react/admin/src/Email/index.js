import React from 'react';
import './Email.css';
import Mailboxes from './Mailboxes';
import Messages from './Messages';

class Email extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      label: "INBOX"
    };
  }

  render() {
    return (
      <>
        <div>Email</div>
        <Mailboxes></Mailboxes>
        <Messages></Messages>
      </>
    );
  }
}

export default Email;