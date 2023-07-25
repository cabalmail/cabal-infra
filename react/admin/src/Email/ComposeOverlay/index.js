import React from 'react';
import './ComposeOverlay.css';
import ApiClient from '../../ApiClient';
import Request from '../../Addresses/Request';
import { ADDRESS_LIST } from '../../constants';
import { EditorState, ContentState, convertToRaw, convertFromRaw, convertFromHTML } from 'draft-js';
import draftToHtml from 'draftjs-to-html';
import { draftToMarkdown } from 'markdown-draft-js';
import { Editor } from "react-draft-wysiwyg";
import "react-draft-wysiwyg/dist/react-draft-wysiwyg.css";

const STATE_KEY = 'compose-state';
const DRAFT_KEY = 'draft-js'
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
  showRequest: false
};

class ComposeOverlay extends React.Component {

  constructor(props) {
    super(props);

    let init_ed_state = null;
    let init_state = null;
    const raw_from_store = localStorage.getItem(DRAFT_KEY);
    
    if (raw_from_store) {
    	const raw_content = convertFromRaw(JSON.parse(raw_from_store));
    	init_ed_state = EditorState.createWithContent(raw_content);
    } else if (this.props.body) {
      init_ed_state - EditorState.createWithContent(
        ContentState.createFromBlockArray(
          convertFromHTML(this.props.body)
        )
      );
    } else {
    	init_ed_state = EditorState.createEmpty();
    }

    let state_from_store = localStorage.getItem(STATE_KEY);
    if (state_from_store) {
      init_state = JSON.parse(state_from_store);
      this.state = {
        editorState: init_ed_state,
        addresses: init_state.addresses,
        address: init_state.address,
        recipient: init_state.recipient,
        validation_fail: init_state.validation_fail,
        To: init_state.To,
        CC: init_state.CC,
        BCC: init_state.BCC,
        Subject: init_state.Subject,
        showRequest: init_state.showRequest
      };
    } else {
      this.state = {
        ...EMPTY_STATE,
        editorState: init_ed_state
      };
    }
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  setState(state) {
  	var raw_content = convertToRaw(state.editorState.getCurrentContent());
    var other_state = {
      // editorState omitted intentionally
      addresses: state.hasOwnProperty('addresses') ? state.addresses : this.state.addresses,
      address: state.hasOwnProperty('address') ? state.address : this.state.address,
      recipient: state.hasOwnProperty('recipient') ? state.recipient : this.state.recipient,
      validation_fail: state.hasOwnProperty('validation_fail') ? state.validation_fail : this.state.validation_fail,
      To: state.hasOwnProperty('To') ? state.To : this.state.To,
      CC: state.hasOwnProperty('CC') ? state.CC : this.state.CC,
      BCC: state.hasOwnProperty('BCC') ? state.BCC : this.state.BCC,
      Subject: state.hasOwnProperty('Subject') ? state.Subject : this.state.Subject,
      showRequest: state.hasOwnProperty('showRequest') ? state.showRequest : this.state.showRequest
    };
    try {
    	localStorage.setItem(DRAFT_KEY, JSON.stringify(raw_content));
    } catch (e) {
      console.error(e);
    }
    try {
      localStorage.setItem(STATE_KEY, JSON.stringify(other_state));
    } catch (e) {
      console.error(e);
    }
    super.setState(state);
  }
  componentDidMount() {
    this.setState({
      ...this.state,
      address: this.props.recipient,
      To: this.props.envelope.from,
      Subject: this.props.subject
    });
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

  componentDidUpdate(prevProps, _prevState) {
  }

  handleSubmit = (e) => {
    e.preventDefault();
    return false;
  }

  handleSend = (e) => {
    e.preventDefault();
    const send_button = e.target;
    send_button.classList.add('sending');
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
    this.api.sendMessage(
      this.props.smtp_host,
      this.state.address,
      this.state.To,
      this.state.CC,
      this.state.BCC,
      this.state.Subject,
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
      console.error(e);
    }
  };

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
      return <option>Loading...</option>;
    }
    return this.state.addresses.map((a) => {
      return <option value={a}>{a}</option>;
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
            tabindex="0"
          >
            {to_list}
            {cc_list}
            {bcc_list}
            <li class="recipient-entry">
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
