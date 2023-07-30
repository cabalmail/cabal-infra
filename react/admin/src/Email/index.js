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

  hideCompose = (envelope) => {
    this.setState({...this.state, composeVisible: false});
  }

  newEmail = () => {
    this.setState(
      {...this.state,
      new_envelope: EMPTY_ENVELOPE,
      subject: "",
      recipient: "",
      body: "",
      type: "new",
      other_headers: {
        in_reply_to: [],
        references: [],
        message_id: []
      },
      composeVisible: true}
      );
  }

  prepBody(body, envelope) {
    return '<div><p>&#160;</p></div><div><hr /></div>' +
      `<div style="font-weight: bold;">From: ${envelope.from[0]}</div>` +
      `<div style="font-weight: bold;">To: ${envelope.to.join("; ")}</div>` +
      `<div style="font-weight: bold;">Date: ${envelope.date}</div>` +
      `<div style="font-weight: bold;">Subject: ${envelope.subject}</div><div><p>&#160;</p></div>` +
      body.replace(/<!--[\s\S]*?-->/gm, "").replace(/&lt;!--[\s\S]*?--&gt;/gm, "")
      .replace(/[\s\S]*<body>/m, "").replace(/<\/body>[\s\S]*/m, "");
  }

  launchComposer(recipient, body, envelope, other_headers, type) {
    const prefix = type === "forward" ? "Fwd: " : "Re: ";
    const subject = prefix + envelope.subject.replace(/^(re:?\s|fwd?:?\s)?/i, "");
    const extended_body = this.prepBody(body, envelope);
    this.setState({
      ...this.state,
      new_envelope: envelope,
      subject: subject,
      recipient: recipient,
      body: extended_body,
      type: type,
      other_headers: other_headers,
      composeVisible: true
    });
  }

  reply = (recipient, body, envelope, other_headers) => {
    this.launchComposer(recipient, body, envelope, other_headers, "reply");
  }

  replyAll = (recipient, body, envelope, other_headers) => {
    this.launchComposer(recipient, body, envelope, other_headers, "replyAll");
  }

  forward = (recipient, body, envelope, other_headers) => {
    this.launchComposer(recipient, body, envelope, other_headers, "forward");
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
            body={this.state.body}
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
          replyAll={this.replyAll}
          forward={this.forward}
        />
        <button className="compose-button" onClick={this.newEmail}>New Email</button>
        {compose_overlay}
      </div>
    );
  }
}

export default Email;