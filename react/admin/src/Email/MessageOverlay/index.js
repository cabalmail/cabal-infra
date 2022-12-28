import React from 'react';
import RichMessage from './RichMessage';
import ApiClient from '../ApiClient';
import './MessageOverlay.css';

class MessageOverlay extends React.Component {

  const api = new ApiClient();
  constructor(props) {
    super(props);
    this.state = {
      message_raw: "",
      message_raw_url: "",
      message_body: "",
      view: "rich",
      attachments: [],
      loading: true,
      top_state: "expanded"
    }
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.envelope.id !== prevProps.envelope.id) {
      this.setState({...this.state, loading: true, invert: false});
      const messageResponse = api.getMessage(
        this.props.folder,
        this.props.host,
        this.props.envelope.id,
        this.props.envelope.flags.includes("\\Seen"),
        this.props.api_url,
        this.props.token
      );
      const attachmentResponse = api.getAttachments(
        this.props.folder,
        this.props.host,
        this.props.envelope.id,
        this.props.envelope.flags.includes("\\Seen"),
        this.props.api_url,
        this.props.token
      );
      Promise.all([
        messageResponse.catch(e => {
          this.props.setMessage("Unable to get message.", true);
          console.log(e);
        }),
        attachmentResponse.catch(e => {
          this.props.setMessage("Unable to get list of attachments.", true);
          console.log(e);
        })
      ]).then(data => {
        const view =
          data[0].data.message_body_plain.length > data[0].data.message_body_html
          ? "plain"
          : "rich";
        this.setState({
          ...this.state,
          message_raw_url: data[0].data.message_raw,
          message_body_plain: data[0].data.message_body_plain,
          message_body_html: data[0].data.message_body_html,
          attachments: data[1].data.attachments,
          loading: false,
          view: view
        });
      }).catch();
    }
  }

  hide = (e) => {
    e.preventDefault();
    this.setState({...this.state, top_state: "expanded"});
    this.props.hide();
  }

  downloadAttachment = (e) => {
    e.preventDefault();
    var id = parseInt(e.target.dataset.id);
    var a = this.state.attachments.find(e => e.id === id);
    api.getAttachment(
      a,
      this.props.folder,
      this.props.host,
      this.props.envelope.id,
      this.props.envelope.flags.includes("\\Seen"),
      this.props.api_url,
      this.props.token
    )
    .then((data) => {
      var url = data.data.url;
      window.open(url);
    })
    .catch((e) => {
      this.props.setMessage("Unable to download attachment.", true);
      console.log(e);
    });
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
          <RichMessage
            body={this.state.message_body_html}
            seen={this.props.envelope.flags.includes("\\Seen")}
            id={this.props.envelope.id}
            folder={this.props.folder}
            host={this.props.host}
            token={this.props.token}
            api_url={this.props.api_url}
            setMessage={this.props.setMessage}
          />
        );
      case "plain":
        return (
          <pre className="message message_plain">{this.state.message_body_plain}</pre>
        );
      case "raw":
        return (
          <div  className="message_raw"><iframe src={this.state.message_raw_url} title="Raw message"></iframe></div>
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
          title="Show the HTML formatted version"
        >Rich Text</button>
        <button
          className={`tab ${this.state.view === "plain" ? "active" : ""}`}
          onClick={this.handleNav}
          value="plain"
          title="Show the plain text version"
        >Plain Text</button>
        <button
          className={`tab ${this.state.view === "attachments" ? "active" : ""}`}
          onClick={this.handleNav}
          value="attachments"
          title="Show attachments"
        >📎</button>
        <button
          className={`tab ${this.state.view === "raw" ? "active" : ""}`}
          onClick={this.handleNav}
          value="raw"
          title="View the raw message source"
        >&lt;/&gt;</button>
      </div>
    );
  }  

  collapse = (e) => {
    e.preventDefault();
    this.setState({...this.state, top_state: "collapsed"});
  }

  expand = (e) => {
    e.preventDefault();
    this.setState({...this.state, top_state: "expanded"});
  }

  handleNav = (e) => {
    e.preventDefault();
    this.setState({...this.state, view: e.target.value});
  }

  render() {
    if (this.props.visible) {
      return (
        <div className="message_overlay">
          <div className={`message_top ${this.state.top_state}`}>
            <button
              onClick={this.hide}
              className="close_overlay"
              title="Close message"
            >❌</button>
            <button
              onClick={this.collapse}
              className="overlay_expand_collapse collapse_overlay_top"
              title="Hide message header"
            >⋀</button>
            <button
              onClick={this.expand}
              className="overlay_expand_collapse expand_overlay_top"
              title="Show message header"
            >⋁</button>
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
