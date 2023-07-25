import React from 'react';
import './Email.css';
import Messages from './Messages';
import MessageOverlay from './MessageOverlay';
import ComposeOverlay from './ComposeOverlay';

const EMPTY_ENVELOPE = {
  from: [],
  to: [],
  subject: ""
};

class Email extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      folder: "INBOX",
      overlayVisible: false,
      composeVisible: false,
      recipient: "",
      envelope: {},
      new_envelope: EMPTY_ENVELOPE,
      body: "",
      other_headers: {},
      flags: [],
      type: "new"
    };
  }

  selectFolder = (folder) => {
    this.setState({...this.state, folder: folder});
  }

  showOverlay = (envelope) => {
    this.setState({
      ...this.state,
      overlayVisible: true,
      envelope: envelope,
      flags: envelope.flags
    });
  }

  hideOverlay = () => {
    this.setState({...this.state, overlayVisible: false});
  }

  newEmail = () => {
    this.setState(
      {...this.state,
      new_envelope: EMPTY_ENVELOPE,
      subject: "",
      recipient: "",
      body: "",
      type: "new",
      other_headers: {},
      composeVisible: true}
      );
  }

  hideCompose = (envelope) => {
    this.setState({...this.state, composeVisible: false});
  }

  reply = (recipient, body, envelope, other_headers) => {
    const subject = envelope.subject.replace(/^(re|fwd):?\s(.$)$/i, "Re: $2");
    this.setState({
      ...this.state,
      new_envelope: envelope,
      subject: subject,
      recipient: recipient,
      body: body,
      type: "reply",
      other_headers: other_headers,
      composeVisible: true
    });
  }

  render() {
    const compose_overlay = this.state.composeVisible ? (
      <div className="compose-blackout" id="compose-blackout">
        <div className="compose-wrapper show-compose" id="compose-wrapper">
          <ComposeOverlay
            token={this.props.token}
            api_url={this.props.api_url}
            host={this.props.host}
            smtp_host={this.props.smtp_host}
            hide={this.hideCompose}
            domains={this.props.domains}
            setMessage={this.props.setMessage}
            quotedMessage={this.state.body}
            recipient={this.state.recipient}
            envelope={this.state.new_envelope}
            subject={this.state.subject}
            type={this.state.type}
            other_headers={this.state.other_headers}
          />
        </div>
      </div>
    ) : "";
    return (
      <div className="email">
        <Messages 
          token={this.props.token}
          api_url={this.props.api_url}
          folder={this.state.folder}
          host={this.props.host}
          showOverlay={this.showOverlay}
          setFolder={this.selectFolder}
          setMessage={this.props.setMessage}
        />
        <MessageOverlay 
          token={this.props.token}
          api_url={this.props.api_url}
          envelope={this.state.envelope}
          flags={this.state.flags}
          visible={this.state.overlayVisible}
          folder={this.state.folder}
          host={this.props.host}
          hide={this.hideOverlay}
          updateOverlay={this.showOverlay}
          setMessage={this.props.setMessage}
          reply={this.reply}
        />
        <button className="compose-button" onClick={this.newEmail}>New Email</button>
        {compose_overlay}
      </div>
    );
  }
}

export default Email;