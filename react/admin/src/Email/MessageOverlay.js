import React from 'react';
import axios from 'axios';
import DOMPurify from 'dompurify';

class MessageOverlay extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      message_raw: "",
      message_body: "",
      view: "rich",
      attachments: [],
      loading: true
    }
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.envelope.id !== prevProps.envelope.id) {
      this.setState({loading: true});
      const messageResponse = this.getMessage();
      const attachmentResponse = this.getAttachments();
      Promise.all([messageResponse, attachmentResponse]).then(data => {
        const view =
          data[0].data.data.message_body_plain.length > data[0].data.data.message_body_html
          ? "plain"
          : "rich";
        this.setState({
          message_raw: data[0].data.data.message_raw,
          message_body_plain: data[0].data.data.message_body_plain,
          message_body_html: DOMPurify.sanitize(data[0].data.data.message_body_html),
          attachments: data[1].data.data.attachments,
          loading: false,
          view: view
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
        host: this.props.host,
        id: this.props.envelope.id
      }),
      {
        baseURL: this.props.api_url,
        headers: {
          'Authorization': this.props.token
        },
        timeout: 20000
      }
    );
    return response;
  }

  getAttachments = async (e) => {
    const response = await axios.post('/list_attachments',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        mailbox: this.props.mailbox,
        host: this.props.host,
        id: this.props.envelope.id
      }),
      {
        baseURL: this.props.api_url,
        headers: {
          'Authorization': this.props.token
        },
        timeout: 20000
      }
    );
    return response;
  }

  hide = (e) => {
    e.preventDefault();
    this.props.hide();
  }

  downloadAttachment = (e) => {
    e.preventDefault();
    // TODO: implement download
    const id = e.target.value;
    console.log(`Download attachment ${id} button clicked`);
  }
 
  renderView() {
    if (this.state.loading) {
      return (
        <div className="message message_loading" />
      );
    }
    switch (this.state.view) {
      case "rich":
        return (
          <div className="message message_html" dangerouslySetInnerHTML={{__html: this.state.message_body_html}} />
        );
      case "plain":
        return (
          <pre className="message message_plain">{this.state.message_body_plain}</pre>
        );
      case "raw":
        return (
          <pre className="message message_raw">{this.state.message_raw}</pre>
        );
      case "attachments":
        const attachments = this.state.attachments.map(a => {
          return (
            <button
              id={`attachment-${a.id}`}
              className="attachment"
              value={a.id}
              onClick={this.downloadAttachment}
            >
              <span className="attachment_name">{a.name}</span>
              <span className="attachment_type">{a.type}</span>
            </button>
          );
        });
        return (
          <div className="message message_attachments">{attachments}</div>
        );
      default:
        return (
          <pre className="message message_raw">{this.state.message_raw}</pre>
        );
    }
  }

  renderHeader() {
    return (
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
    );
  }

  renderButtonBar() {
    return (
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
          className={`tab ${this.state.view === "attachments" ? "active" : ""}`}
          onClick={this.handleNav}
          value="attachments"
        >Attachments</button>
        <button
          className={`tab ${this.state.view === "raw" ? "active" : ""}`}
          onClick={this.handleNav}
          value="raw"
        >Raw Message</button>
      </div>
    );
  }  

  handleNav = (e) => {
    e.preventDefault();
    this.setState({view: e.target.value});
  }

  render() {
    if (this.props.visible) {
      return (
        <div className="message_overlay">
          <div className="message_top">
            <button onClick={this.hide} className="close_overlay">❌</button>
            {this.renderHeader()}
            {this.renderButtonBar()}
          </div>
          {this.renderView()}
        </div>
      );
    }
    return <div className="message_overlay overlay_hidden"></div>;
  }
}

export default MessageOverlay;
