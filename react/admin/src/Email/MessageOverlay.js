import React from 'react';
import axios from 'axios';
import DOMPurify from 'dompurify';

class MessageOverlay extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      message_raw: "",
      message_body: "",
      view: "rich"
    }
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.envelope.id !== prevProps.envelope.id) {
      const response = this.getMessage();
      response.then(data => {
        this.setState({
          message_raw: data.data.data.message_raw,
          message_body_plain: data.data.data.message_body_plain,
          message_body_html: DOMPurify.sanitize(data.data.data.message_body_html)
        });
      });
    }
  }

  getMessage = async (e) => {
    const response = await axios.post('/fetch_message',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        mailbox: this.props.mailbox,
        id: this.props.envelope.id
      }),
      {
        baseURL: this.props.api_url,
        headers: {
          'Authorization': this.props.token
        },
        timeout: 10000
      }
    );
    return response;
  }

  hide = (e) => {
    e.preventDefault();
    this.props.hide();
  }

  renderView() {
    switch (this.state.view) {
      case "rich":
        return (
          <div className="message_html" dangerouslySetInnerHTML={{__html: this.state.message_body_html}} />
        );
      case "plain":
        return (
          <pre className="message_plain">{this.state.message_body_plain}</pre>
        );
      case "raw":
        return (
          <pre className="message_raw">{this.state.message_raw}</pre>
        );
      default:
        return (
          <div className="message_html" dangerouslySetInnerHTML={{__html: this.state.message_body_html}} />
        );
    }
  }

  handleNav = (e) => {
    e.preventDefault();
    this.setState({view: e.target.value});
  }

  render() {
    if (this.props.visible) {
      return (
        <div className="message_overlay">
          <button onClick={this.hide} className="close_overlay">❌</button>
          <dl>
            <dt>To</dt>
            <dd>{this.props.envelope.to}</dd>
            <dt>From</dt>
            <dd>{this.props.envelope.from.join("; ")}</dd>
            <dt>Received</dt>
            <dd>{this.props.envelope.date}</dd>
            <dt>Subject</dt>
            <dd>{this.props.envelope.subject}</dd>
          </dl>
          <div className={`tabBar ${this.state.view}`}>
            <button
              className={`tab ${this.state.view === "rich" ? "active" : ""}`}
              onClick={this.handleNav}
              value="rich"
            >Rich Text</button>
            <button
              className={`tab ${this.state.view === "plain" ? "active" : ""}`}
              onClick={this.handleNav}
              value="plain"
            >Plain Text</button>
            <button
              className={`tab ${this.state.view === "raw" ? "active" : ""}`}
              onClick={this.handleNav}
              value="raw"
            >Raw Message</button>
          </div>
          {this.renderView()}
        </div>
      );
    }
    return <div className="message_overlay overlay_hidden"></div>;
  }
}

export default MessageOverlay;
