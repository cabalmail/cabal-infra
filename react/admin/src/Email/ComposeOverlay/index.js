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
    	const raw = convertFromRaw(JSON.parse(raw_from_store));
    	init_ed_state = EditorState.createWithContent(raw);
    } else {
    	init_ed_state = EditorState.createEmpty();
    }

    let state_from_store = localStorage.getItem(STATE_KEY);
    if (state_from_store) {
      init_state = JSON.parse(state_from_store);
      init_state.editorState = init_ed_state;
    } else {
      init_state = {
        editorState: init_ed_state,
        addresses: [],
        address: "",
        To: null,
        CC: null,
        BCC: null,
        Subject: null,
        showRequest: false
      };
    }
    this.state = init_state;
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  setState(state) {
  	var raw = convertToRaw(state.editorState.getCurrentContent());
  	localStorage.setItem(DRAFT_KEY, JSON.stringify(raw));
    var other_state = JSON.parse(JSON.stringify(state));
    delete other_state.editorState;
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
      this.setState({...this.state, addresses: data.data.Items.map(a => a.address).sort()});
    });
  }

  getOptions() {
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
    this.props.hide();
    return false;
  }

  handleCancel = (e) => {
    e.preventDefault();
    // TODO: clear all inputs
    this.props.hide();
  }

  onMessageChange = (editorState) => {
    this.setState({...this.state, editorState});
  }

  onSelectChange = (e) => {
    this.setState({...this.state, address: e.target.value});
  }

  onToChange = (e) => {
    this.setState({...this.state, To: e.target.value});
  }

  onCcChange = (e) => {
    this.setState({...this.state, CC: e.target.value});
  }

  onBccChange = (e) => {
    this.setState({...this.state, BCC: e.target.value});
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
      editorState,
    });
  };

  render() {
    const { editorState } = this.state;
    return (
      <form className="compose-overlay" onSubmit={this.handleSubmit}>
        <div className="compose-from-old">
          <label for="address-from-old" className="address-from-old">From</label>
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
        <label for="address-to">To</label>
        <input
          type="email"
          id="address-to"
          name="address-to"
          onChange={this.onToChange}
          value={this.state.To}
        />
        <label htmlFor="address-cc">CC</label>
        <input
          type="email"
          id="address-cc"
          name="address-cc"
          onChange={this.onCcChange}
          value={this.state.CC}
        />
        <label htmlFor="address-bcc">BCC</label>
        <input
          type="email"
          id="address-bcc"
          name="address-cc"
          onChange={this.onBccChange}
          value={this.state.BCC}
        />
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