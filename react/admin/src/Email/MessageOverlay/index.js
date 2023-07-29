import React from 'react';
import RichMessage from './RichMessage';
import Actions from '../Actions';
import ApiClient from '../../ApiClient';
import './MessageOverlay.css';

class MessageOverlay extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      message_raw: "",
      message_raw_url: "",
      message_body_plain: "",
      message_body_html: "",
      view: "rich",
      attachments: [],
      loading: true,
      top_state: "expanded",
      bimi_url: "/mask.png",
      recipient: "",
      message_id: [],
      in_reply_to: [],
      references: []
    }
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.envelope.id !== prevProps.envelope.id) {
      this.setState({...this.state, loading: true, invert: false});

      this.api.getMessage(
        this.props.folder,
        this.props.envelope.id,
        this.props.envelope.flags.includes("\\Seen")
      ).then(data => {
        const view =
          data.data.message_body_plain.length > data.data.message_body_html
          ? "plain"
          : "rich";
        this.setState({
          ...this.state,
          message_raw_url: data.data.message_raw,
          message_body_plain: data.data.message_body_plain,
          message_body_html: data.data.message_body_html,
          recipient: data.data.recipient,
          message_id: data.data.message_id,
          in_reply_to: data.data.in_reply_to,
          references: data.data.references,
          loading: false,
          view: view
        });
      }).catch(e => {
        this.props.setMessage("Unable to get message.", true);
        console.log(e);
      });

      this.api.getAttachments(
        this.props.folder,
        this.props.envelope.id,
        this.props.envelope.flags.includes("\\Seen")
      ).then(data => {
        this.setState({
          ...this.state,
          attachments: data.data.attachments
        });
      }).catch(e => {
        this.props.setMessage("Unable to get list of attachments.", true);
        console.log(e);
      });

      this.api.getBimiUrl(
        this.props.envelope.from[0]
      ).then(data => {
        this.setState({
          ...this.state,
          bimi_url: data.data.url
        });
      }).catch(e => {
        console.log(e);
      });
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
    this.api.getAttachment(
      a,
      this.props.folder,
      this.props.envelope.id,
      this.props.envelope.flags.includes("\\Seen")
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

  callback = (d) => {
    this.api.getEnvelopes(this.props.folder, [this.props.envelope.id]).then(data => {
      this.props.updateOverlay(data.data.envelopes[this.props.envelope.id]);
    });
  }

  catchback = (err) => {
    this.props.setMessage("Unable to set flag on message.", true);
    console.log(`Unable to set flag on message.`);
    console.log(err);
  };

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

  reply = () => {
    this.props.reply(
      this.state.recipient,
      this.state.message_body_html || this.stage.message_body_plain,
      this.props.envelope,
      {
        message_id: this.state.message_id,
        in_reply_to: this.state.in_reply_to,
        references: this.state.references
      }
    );
  }

  replyAll = () => {
  }

  forward = () => {
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
    const cc = this.props.cc ? (
      <>
        <dt className="collapsable">CC</dt>
        <dd className="collapsable">{this.props.envelope.cc.join("; ")}</dd>
      </>
    ) : ""
    return (
      <dl>
        <dt className="collapsable">From</dt>
        <dd className="collapsable">{this.props.envelope.from.join("; ")}</dd>
        <dt className="collapsable">To</dt>
        <dd className="collapsable">{this.props.envelope.to.join("; ")}</dd>
        {cc}
        <dt className="collapsable">Received</dt>
        <dd className="collapsable">{this.props.envelope.date}</dd>
        <dt className="collapsable">Subject</dt>
        <dd>{this.props.envelope.subject}</dd>
      </dl>
    );
  }

  renderTabBar() {
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

  render() {
    const flags = this.props.flags.map(d => {return d.replace("\\","")}).join(" ");
    if (this.props.visible) {
      return (
        <div className="message_overlay">
          <div className={`message_top ${this.state.top_state} ${flags}`}>
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
            <Actions
              token={this.props.token}
              api_url={this.props.api_url}
              host={this.props.host}
              folder={this.props.folder}
              selected_messages={[this.props.envelope.id]}
              selected="selected "
              order=""
              field="ARRIVAL"
              callback={this.callback}
              catchback={this.catchback}
              reply={this.reply}
              replyAll={this.replyAll}
              forward={this.forward}
              setMessage={this.props.setMessage}
            />
            <button
              onClick={this.hide}
              className="close_overlay"
              title="Close message"
            >❌</button>
            {this.renderHeader()}
            {this.renderTabBar()}
            <div className="bimi">
              <img src={this.state.bimi_url} alt="" />
            </div>
          </div>
          {this.renderView()}
        </div>
      );
    }
    return <div className="message_overlay overlay_hidden"></div>;
  }
}

export default MessageOverlay;
