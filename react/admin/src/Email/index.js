import React from 'react';
import './Email.css';
import Mailboxes from './Mailboxes';
import Messages from './Messages';
import MessageOverlay from './MessageOverlay';

class Email extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      mailbox: "INBOX",
      overlayVisible: false,
      envelope: {}
    };
  }

  selectMailbox = (mailbox) => {
    this.setState({mailbox: mailbox});
  }

  showOverlay = (envelope) => {
    this.setState({
      overlayVisible: true,
      envelope: envelope
    });
  }

  hideOverlay = () => {
    this.setState({overlayVisible: false});
  }

  render() {
    return (
      <>
        <MessageOverlay 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          api_url={this.props.api_url}
          envelope={this.state.envelope}
          visible={this.state.overlayVisible}
          hide={this.hideOverlay}
        />
        <Mailboxes 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          api_url={this.props.api_url}
          setMailbox={this.selectMailbox}
          mailbox={this.state.mailbox}
        />
        <Messages 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          api_url={this.props.api_url}
          mailbox={this.state.mailbox}
          showOverlay={this.showOverlay}
        />
      </>
    );
  }
}

export default Email;