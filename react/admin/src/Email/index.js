import React from 'react';
import './Email.css';
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
    this.setState({...this.state, mailbox: mailbox});
  }

  showOverlay = (envelope) => {
    this.setState({
      ...this.state,
      overlayVisible: true,
      envelope: envelope
    });
  }

  hideOverlay = () => {
    this.setState({...this.state, overlayVisible: false});
  }

  render() {
    return (
      <div className="email">
        <Messages 
          token={this.props.token}
          password={this.props.password}
          userName={this.props.userName}
          api_url={this.props.api_url}
          mailbox={this.state.mailbox}
          host={this.props.host}
          showOverlay={this.showOverlay}
          setMailbox={this.selectMailbox}
          setMessage={this.props.setMessage}
        />
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
      </div>
    );
  }
}

export default Email;