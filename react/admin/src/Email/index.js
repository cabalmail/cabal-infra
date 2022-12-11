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
          mailbox={this.state.mailbox}
          host={this.props.host}
          hide={this.hideOverlay}
          setMessage={this.props.setMessage}
        />
        <Mailboxes 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          api_url={this.props.api_url}
          setMailbox={this.selectMailbox}
          host={this.props.host}
          mailbox={this.state.mailbox}
          setMessage={this.props.setMessage}
        />
        <Messages 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          api_url={this.props.api_url}
          mailbox={this.state.mailbox}
          host={this.props.host}
          showOverlay={this.showOverlay}
          setMessage={this.props.setMessage}
        />
      </>
    );
  }
}

export default Email;