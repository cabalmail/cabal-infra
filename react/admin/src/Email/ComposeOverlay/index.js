import React from 'react';
import './ComposeOverlay.css';
import ApiClient from '../../ApiClient';
import Request from '../../Addresses/Request';
import { ADDRESS_LIST } from '../../constants';
import { EditorState, ContentState, convertToRaw } from 'draft-js';
import draftToHtml from 'draftjs-to-html';
import htmlToDraft from 'html-to-draftjs';
import { draftToMarkdown } from 'markdown-draft-js';
import { Editor } from "react-draft-wysiwyg";
import "react-draft-wysiwyg/dist/react-draft-wysiwyg.css";

const MESSAGE = {
  target: {
    id: "recipient-to"
  }
};
const EMPTY_STATE = {
  addresses: [],
  address: "",
  recipient: "",
  validation_fail: false,
  To: [],
  CC: [],
  BCC: [],
  Subject: "",
  message_id: "",
  showRequest: false
};

class ComposeOverlay extends React.Component {

  constructor(props) {
    super(props);
    let init_ed_state = null;
    if (this.props.body) {
      const block_array = htmlToDraft(this.props.body);
      const content_state = ContentState.createFromBlockArray(block_array);
      init_ed_state = EditorState.createWithContent(content_state);
    } else {
    	init_ed_state = EditorState.createEmpty();
    }

    this.state = {
      ...EMPTY_STATE,
      editorState: init_ed_state
    };
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  componentDidMount() {
    switch (this.props.type) {
      case "reply":
        this.setState({
          ...this.state,
          address: this.props.recipient,
          To: this.props.envelope.from,
          CC: [],
          Subject: this.props.subject
        });
        break;
      case "replyAll":
        let to_list = [...new Set([
                        ...(this.props.envelope.from),
                        ...(this.props.envelope.to || [])
                      ])];
        const i = to_list.indexOf(this.props.recipient);
        if (i > -1) {
          to_list.splice(i, 1);
        }
        let cc_list = this.props.envelope.cc.slice();
        const j = cc_list.indexOf(this.props.recipient);
        if (j > -1) {
          cc_list.splice(j, 1);
        }
        if (i === -1 && j === -1) {
          this.props.setMessage("Warning: You are replying to a blind copy.", true);
        }
        this.setState({
          ...this.state,
          address: this.props.recipient,
          To: to_list,
          CC: cc_list,
          Subject: this.props.subject
        });
        break;
      case "forward":
        this.setState({
          ...this.state,
          address: this.props.recipient,
          To: [],
          CC: [],
          Subject: this.props.subject
        });
        break;
      default:
        // This must be a new message
        this.setState({...this.state, EMPTY_STATE});
        break;
    }
    this.api.getAddresses().then(data => {
      try {
        localStorage.setItem(ADDRESS_LIST, JSON.stringify(data));
      } catch (e) {
        console.log(e);
      }
      this.setState({
        ...this.state,
        addresses: data.data.Items.map(a => a.address).sort()
      });
    });
  }

  handleSubmit = (e) => {
    e.preventDefault();
    return false;
  }

  handleSend = (e) => {
    e.preventDefault();
    const send_button = e.target;
    const oh = this.props.other_headers;
    const irt = oh.message_id || [];
    const msgid = [ '<' + this.randomString(30) + '@' + this.props.smtp_host + '>' ];
    const ref = [...new Set([
                              ...(oh.references || []),
                              ...(oh.message_id || []),
                              ...(oh.in_reply_to || [])
                            ])];
    const headers = {
      in_reply_to: irt.map(s => s.trim()),
      message_id: msgid.map(s => s.trim()),
      references: ref.map(s => s.trim())
    }
    if (this.state.recipient) {
      this.addRecipient(MESSAGE);
    }
    if (this.state.To.length + this.state.CC.length + this.state.BCC.length === 0) {
      this.props.setMessage("Please specify at least one recipient.", true);
      return;
    }
    if (this.state.subject === "") {
      this.props.setMessage("Please provide a subject.", true);
      return;
    }
    if (this.state.addresses.indexOf(this.state.address) === -1) {
      this.props.setMessage("Please select an address from which to send.", true);
      return;
    }
    send_button.classList.add('sending');
    this.api.sendMessage(
      this.props.smtp_host,
      this.state.address,
      this.state.To,
      this.state.CC,
      this.state.BCC,
      this.state.Subject,
      headers,
      draftToHtml(convertToRaw(this.state.editorState.getCurrentContent())),
      draftToMarkdown(convertToRaw(this.state.editorState.getCurrentContent())),
      false
    ).then(() => {
      this.props.setMessage("Email sent", false);
      this.setState({
        ...EMPTY_STATE,
        editorState: EditorState.createEmpty()
      });
      this.props.hide();
      send_button.classList.remove('sending');
    }).catch((e) => {
      this.props.setMessage("Error sending email", true);
      send_button.classList.remove('sending');
      console.log(e);
    });
  }

  handleCancel = (e) => {
    e.preventDefault();
    this.props.hide();
  }

  onEditorStateChange = (editorState) => {
    this.setState({
      ...this.state,
      editorState: editorState
    });
    try {
      window.getSelection().getRangeAt(0).commonAncestorContainer.parentNode
        .scrollIntoView({ behavior: "smooth", block: "nearest", inline: "nearest" });
    } catch (e) {
      if (e.name !== "IndexSizeError") {
        // OK to ignore IndexSizeError
        console.error(e);
      }
    }
  };

  randomString(length) {
    let str = '';
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    const len = chars.length;
    for (var i = 0; i < length; i++) {
      str += chars.charAt(Math.floor(Math.random() * len));
    }
    return str;
  }

  validateAddress(address) {
    // Not going to allow IP addresses; domains only
    let re = /(([^<>()[\]\\.,;:\s@"]+(\.[^<>()[\]\\.,;:\s@"]+)*)|.(".+"))@((([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))/;
    return address.match(re);
  }

  addRecipient = (e) => {
    const address = this.state.recipient;
    if (this.validateAddress(address)) {
      let to_list = this.state.To.slice();
      let cc_list = this.state.CC.slice();
      let bcc_list = this.state.BCC.slice();
      const union_list = to_list.concat(cc_list, bcc_list);
      if (union_list.indexOf(address) > -1) {
        return;
      }
      switch (e.target.id) {
        case "recipient-to":
          to_list.push(address);
          break;
        case "recipient-cc":
          cc_list.push(address);
          break;
        case "recipient-bcc":
          bcc_list.push(address);
          break;
        default:
          to_list.push(address);
      }
      this.setState({
        ...this.state,
        To: to_list,
        CC: cc_list,
        BCC: bcc_list,
        recipient: ""
      });
    } else {
      this.setState({...this.state, validation_fail: true});
    }
  }

  onSelectChange = (e) => {
    if (e.target.value === "new") {
      this.setState({...this.state, address: e.target.value, showRequest: true});
      return;
    }
    this.setState({...this.state, address: e.target.value, showRequest: false});
  }

  onRecipientChange = (e) => {
    this.setState({...this.state, recipient: e.target.value});
  }

  handleKeyDown = (e) => {
    if (e.key === "Enter" || e.key === " " || e.key === ";" || e.key === ",") {
      e.preventDefault();
      this.addRecipient(MESSAGE);
    }
    if (e.key === "Tab") {
      this.addRecipient(MESSAGE);
    }
  }

  onSubjectChange = (e) => {
    this.setState({...this.state, Subject: e.target.value});
  }

  requestCallback = (address) => {
    var addressList = this.state.addresses;
    addressList.push(address);
    this.setState({
      ...this.state,
      addresses: addressList,
      address: address,
      showRequest: false
    });
  }

  removeTo = (e) => {
    let to_list = this.state.To.slice();
    const i = to_list.indexOf(e.target.value);
    if (i > -1) {
      to_list.splice(i, 1);
      this.setState({...this.state, To: to_list, recipient: e.target.value});
    }
  }

  removeCC = (e) => {
    let cc_list = this.state.CC.slice();
    const i = cc_list.indexOf(e.target.value);
    if (i > -1) {
      cc_list.splice(i, 1);
      this.setState({...this.state, CC: cc_list, recipient: e.target.value});
    }
  }

  removeBCC = (e) => {
    let bcc_list = this.state.BCC.slice();
    const i = bcc_list.indexOf(e.target.value);
    if (i > -1) {
      bcc_list.splice(i, 1);
      this.setState({...this.state, BCC: bcc_list, recipient: e.target.value});
    }
  }

  moveAddress = (e) => {
    const address = e.target.getAttribute('data-address');
    const list = e.target.value;
    let to_list = this.state.To.slice();
    let cc_list = this.state.CC.slice();
    let bcc_list = this.state.BCC.slice();
    const to_i = to_list.indexOf(address);
    if (to_i > -1) {
      to_list.splice(to_i, 1);
    }
    const cc_i = cc_list.indexOf(address);
    if (cc_i > -1) {
      cc_list.splice(cc_i, 1);
    }
    const bcc_i = bcc_list.indexOf(address);
    if (bcc_i > -1) {
      bcc_list.splice(bcc_i, 1);
    }
    switch (list) {
      case "To":
        to_list.push(address);
        break;
      case "CC":
        cc_list.push(address);
        break;
      case "BCC":
        bcc_list.push(address);
        break;
      default:
        to_list.push(address);
    }
    this.setState({
      ...this.state,
      To: to_list,
      CC: cc_list,
      BCC: bcc_list
    });
  }

  getOptions() {
    if (! this.state.addresses) {
      return <option key="loading">Loading...</option>;
    }
    return this.state.addresses.map((a) => {
      return <option value={a} key={a}>{a}</option>;
    });
  }

  obscureEmail(address) {
    return address.split('').map((c) => {
      switch (c) {
        case '.':
          return <span className="dot"></span>
        case '@':
          return <span className="amphora"></span>
        default:
          return <span>{c}</span>
      }
    });
  }

  render() {
    const { editorState } = this.state;
    const to_list = this.state.To.sort().map((a) => {
      return (
        <li key={a} className="To">
          <div><label><select value="To" data-address={a} onChange={this.moveAddress}>
            <option>To</option>
            <option>CC</option>
            <option>BCC</option>
          </select>▼</label>{this.obscureEmail(a)}<button onClick={this.removeTo} value={a}>☒</button></div>
        </li>
        );
    });
    const cc_list = this.state.CC.sort().map((a) => {
      return (
        <li key={a} className="CC">
          <div><label><select value="CC" data-address={a} onChange={this.moveAddress}>
            <option>To</option>
            <option>CC</option>
            <option>BCC</option>
          </select>▼</label>{this.obscureEmail(a)}<button onClick={this.removeCC} value={a}>☒</button></div>
        </li>
        );
    });
    const bcc_list = this.state.BCC.sort().map((a) => {
      return (
        <li key={a} className="BCC">
          <div><label><select value="BCC" data-address={a} onChange={this.moveAddress}>
            <option>To</option>
            <option>CC</option>
            <option>BCC</option>
          </select>▼</label>{this.obscureEmail(a)}<button onClick={this.removeBCC} value={a}>☒</button></div>
        </li>
        );
    });
    return (
      <form className="compose-overlay" onSubmit={this.handleSubmit}>
        <div className="compose-from-old">
          <label htmlFor="address-from-old" className="address-from-old">From</label>
          <select
            type="text"
            id="address-from-old"
            name="address-from-old"
            className="address-from-old"
            placeholder="Find existing address"
            onChange={this.onSelectChange}
            value={this.state.address}
          >
            <option value="">Select an address</option>
            <option value="new">Create a new address</option>
            {this.getOptions()}
          </select>
          <Request
            token={this.props.token}
            domains={this.props.domains}
            api_url={this.props.api_url}
            setMessage={this.props.setMessage}
            showRequest={this.state.showRequest}
            host={this.props.host}
            callback={this.requestCallback}
          />
        </div>
        <label htmlFor="recipient-address">Recipients</label>
        <div
          className="recipients"
          onClick={e => document.getElementById('recipient-address').focus()}
        >
          <ul
            className={"recipient-list"}
            id="recipient-list"
            tabIndex="0"
          >
            {to_list}
            {cc_list}
            {bcc_list}
            <li className="recipient-entry">
              <input
                type="email"
                id="recipient-address"
                name="address-to"
                onChange={this.onRecipientChange}
                onKeyDown={this.handleKeyDown}
                value={this.state.recipient}
                className={`recipient-address${this.state.validation_fail ? " invalid" : ""}`}
              />
            </li>
          </ul>
        </div>
        <label htmlFor="subject">Subject</label>
        <input
          type="text"
          id="subject"
          name="subject"
          onChange={this.onSubjectChange}
          value={this.state.Subject}
        />
        <Editor
          editorState={editorState}
          toolbarClassName="wysiwyg-toolbar"
          wrapperClassName="wysiwyg-wrapper"
          editorClassName="wysiwyg-editor"
          onEditorStateChange={this.onEditorStateChange}
          toolbar={{
            options: ['inline', 'blockType', 'fontSize', 'fontFamily', 'list', 'textAlign', 'colorPicker', 'link', 'embedded', 'emoji', 'remove', 'history'],
            
          }}
        />
        <button onClick={this.handleSend} className="default" id="compose-send">Send</button>
        <button onClick={this.handleCancel} id="compose-cancel">Cancel</button>
      </form>
    );
  }
}

export default ComposeOverlay;
