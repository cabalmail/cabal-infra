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
        <Mailboxes 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          api_url={this.props.api_url}
        />
        <Messages 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          api_url={this.props.api_url}
        />
      </>
    );
  }
}

export default Email;