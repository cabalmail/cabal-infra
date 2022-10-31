import React from 'react';
import './Email.css';
import Mailboxes from './Mailboxes';
import Messages from './Messages';

class Email extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      mailbox: "INBOX"
    };
  }

  selectMailbox = (mailbox) => {
    this.setState({mailbox: mailbox});
  }

  render() {
    return (
      <>
        <Mailboxes 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          api_url={this.props.api_url}
          setMailbox={this.selectMailbox}
        />
        <Messages 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          api_url={this.props.api_url}
          mailbox={this.state.mailbox}
        />
      </>
    );
  }
}

export default Email;