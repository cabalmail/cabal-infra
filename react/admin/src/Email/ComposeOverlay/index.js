import React from 'react';
import './ComposeOverlay.css';
import ApiClient from '../../ApiClient';
import Request from '../../Addresses/Request';
// import Composer from './Composer';
import { ADDRESS_LIST } from '../../constants';
import { EditorState, convertToRaw, convertFromRaw } from 'draft-js';
import { Editor } from "react-draft-wysiwyg";
import "react-draft-wysiwyg/dist/react-draft-wysiwyg.css";

const STATE_KEY = 'compose-state';
const DRAFT_KEY = 'draft-js'

class ComposeOverlay extends React.Component {

  constructor(props) {
    super(props);

    let init_ed_state = null;
    let init_state = null;
    const raw_from_store = localStorage.getItem(DRAFT_KEY);
    
    if (raw_from_store) {
    	const raw_content = convertFromRaw(JSON.parse(raw_from_store));
    	init_ed_state = EditorState.createWithContent(raw_content);
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
        editorState: init_ed_state,
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
    }
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  setState(state) {
  	var raw_content = convertToRaw(state.editorState.getCurrentContent());
    var other_state = {
      // editorState omitted intentionally
      addresses: state.addresses || this.state.addresses,
      address: state.address || this.state.address,
      recipient: state.recipient || this.state.recipient,
      validation_fail: state.validation_fail || this.state.validation_fail,
      To: state.To || this.state.To,
      CC: state.CC || this.state.CC,
      BCC: state.BCC || this.state.BCC,
      Subject: state.Subject || this.state.Subject,
      showRequest: state.showRequest || this.state.showRequest
    };
    try {
    	localStorage.setItem(DRAFT_KEY, JSON.stringify(raw_content));
    } catch (e) {
      console.log(e);
    }
    try {
      localStorage.setItem(STATE_KEY, JSON.stringify(other_state));
    } catch (e) {
      console.log(e);
    }
    super.setState(state);
  }

  componentDidMount() {
    this.getAddresses();
  }

  getAddresses() {
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

  getOptions() {
    if (! this.state.addresses) {
      return <option>Loading...</option>;
    }
    return this.state.addresses.map((a) => {
      return <option value={a}>{a}</option>;
    });
  }

  handleSubmit = (e) => {
    e.preventDefault();
    return false;
  }

  handleSend = (e) => {
    e.preventDefault();
    alert("Not implemented");
    return false;
  }

  handleCancel = (e) => {
    e.preventDefault();
    // TODO: clear all inputs
    this.props.hide();
  }

  validateAddress(address) {
    // Not going to allow IP addresses; domains only
    let re = /^(([^<>()[]\\.,;:\s@"]+(\.[^<>()[]\\.,;:\s@"]+)*)|(".+"))@((([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))$/;

    return re.test(address);
  }

  validateRecipient = (e) => {
    if (!this.validateAddress(e.target.value)) {
      this.setState({...this.state, validation_fail: true});
    } else {
      this.setState({...this.state, validation_fail: false});
    }
  }

  addRecipient = (e) => {
    const address = document.getElementById("recipient-address").value;
    if (this.validateAddress(address)) {
      let to_list = this.state.To.slice();
      let cc_list = this.state.CC.slice();
      let bcc_list = this.state.BCC.clice();
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
        BCC: bcc_list
      })
    } else {
      // Show validation failure
    }
  }

  onSelectChange = (e) => {
    this.setState({...this.state, address: e.target.value});
  }

  onRecipientChange = (e) => {
    this.setState({...this.state, recipient: e.target.value});
  }

  onSubjectChange = (e) => {
    this.setState({...this.state, Subject: e.target.value});
  }

  toggleRequest = () => {
    this.setState({...this.state, showRequest: !this.state.showRequest})
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

  onEditorStateChange = (editorState) => {
    this.setState({
      ...this.state,
      editorState: editorState
    });
  };

  render() {
    const { editorState } = this.state;
    const to_list = this.state.To.map((a) => {
      return (
        <li key={a}><div>To:{a.split('').map((c) => {
          return <span>{c}</span>;
        })}</div></li>
      );
    });
    const cc_list = this.state.CC.map((a) => {
      return (
        <li key={a}><div>CC:{a.split('').map((c) => {
          return <span>{c}</span>;
        })}</div></li>
      );
    });
    const bcc_list = this.state.BCC.map((a) => {
      return (
        <li key={a}><div>BCC:{a.split('').map((c) => {
          return <span>{c}</span>;
        })}</div></li>
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
          ><option value="">Select an address</option>{this.getOptions()}</select>
          <button
            onClick={this.toggleRequest}
            className="toggleRequest"
          >New Address {this.state.showRequest ? "▼" : "▶︎"}</button>
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
        <input
          type="email"
          id="recipient-address"
          name="address-to"
          onChange={this.onRecipientChange}
          onBlur={this.validateRecipient}
          value={this.state.recipient}
          className={`recipient-address${this.state.validation_fail ? " invalid" : ""}`}
        />
        <button
          onClick={this.addRecipient}
          className="default recipient"
          id="recipient-to"
        >+ To</button>
        <button
          onClick={this.addRecipient}
          className="recipient"
          id="recipient-cc"
        >+ CC</button>
        <button
          onClick={this.addRecipient}
          className="recipient"
          id="recipient-bcc"
        >+ BCC</button>
        <div className="recipients">
          <ul className="recipeint-list" id="to-list">{to_list}</ul>
          <ul className="recipient-list" id="cc-list">{cc_list}</ul>
          <ul className="recipient-list" id="bcc-list">{bcc_list}</ul>
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
        />
        <button onClick={this.handleSend} className="default" id="compose-send">Send</button>
        <button onClick={this.handleCancel} id="compose-cancel">Cancel</button>
      </form>
    );
  }
}

export default ComposeOverlay;
