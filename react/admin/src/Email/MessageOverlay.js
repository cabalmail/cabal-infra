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
      loading: true,
      invert: false,
      top_state: "expanded"
    }
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.envelope.id !== prevProps.envelope.id) {
      this.setState({loading: true, invert: false});
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

  getMessage = async () => {
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

  getAttachment = async (a) => {
    const response = await axios.post('/fetch_attachment',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        mailbox: this.props.mailbox,
        host: this.props.host,
        id: this.props.envelope.id,
        index: a.id,
        filename: a.name
      }),
      {
        baseURL: this.props.api_url,
        headers: {
          'Authorization': this.props.token
        },
        timeout: 90000
      }
    );
    return response;
  }

  getAttachments = async () => {
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
    var id = parseInt(e.target.dataset.id);
    var a = this.state.attachments.find(e => e.id === id);
    this.getAttachment(a)
    .then((data) => {
      console.log(data);
      var url = data.data.data.url;
      console.log(url);
      window.open(url);
    })
    .catch((e) => {
      console.log("Download failed");
      console.error(e);
    });
  }

  toggleBackground = (e) => {
    e.preventDefault();
    this.setState({invert: !this.state.invert})
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
          <div className={`message message_html ${this.state.invert ? "inverted" : ""}`}>
            <button className="invert" onClick={this.toggleBackground}>◐</button>
            <div className={this.state.invert ? "inverted" : ""} dangerouslySetInnerHTML={{__html: this.state.message_body_html}} />
          </div>
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
              data-id={a.id}
            >
              <span className="attachment_name" data-id={a.id}>{a.name}</span>
              <span className="attachment_size" data-id={a.id}>{a.size} bytes</span>
              <span className="attachment_type" data-id={a.id}>{a.type}</span>
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
        <dt className="collapsable">To</dt>
        <dd className="collapsable">{this.props.envelope.to.join("; ")}</dd>
        <dt className="collapsable">From</dt>
        <dd className="collapsable">{this.props.envelope.from.join("; ")}</dd>
        <dt className="collapsable">Received</dt>
        <dd className="collapsable">{this.props.envelope.date}</dd>
        <dt className="collapsable">Subject</dt>
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
        >📎</button>
        <button
          className={`tab ${this.state.view === "raw" ? "active" : ""}`}
          onClick={this.handleNav}
          value="raw"
        >&lt;/&gt;</button>
      </div>
    );
  }  

  collapse = (e) => {
    e.preventDefault();
    this.setState({top_state: "collapsed"});
  }

  expand = (e) => {
    e.preventDefault();
    this.setState({top_state: "expanded"});
  }

  handleNav = (e) => {
    e.preventDefault();
    this.setState({view: e.target.value});
  }

  render() {
    if (this.props.visible) {
      return (
        <div className="message_overlay">
          <div className={`message_top ${this.state.top_state}`}>
            <button onClick={this.hide} className="close_overlay">❌</button>
            <button onClick={this.collapse} className="overlay_expand_collapse collapse_overlay_top">∧</button>
            <button onClick={this.expand} className="overlay_expand_collapse expand_overlay_top">∨</button>
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
