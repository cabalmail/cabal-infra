import React from 'react';
import './Email.css';
import Messages from './Messages';
import MessageOverlay from './MessageOverlay';
import ComposeOverlay from './ComposeOverlay';
// const STATE_KEY = 'email-state';

class Email extends React.Component {

  constructor(props) {
    super(props);
    this.state = JSON.parse(localStorage.getItem(STATE_KEY)) || {
      folder: "INBOX",
      overlayVisible: false,
      composeVisible: false,
      envelope: {},
      flags: []
    };
  }

  // componentWillUnmount() {
  //   // hide the overlay when switching to this component,
  //   // even if saved state wants to show it
  //   this.setState({...this.state, overlayVisible: false, composeVisible: false, envelope: {}});
  // }
  // setState(state) {
  //   try {
  //     localStorage.setItem(STATE_KEY, JSON.stringify(state));
  //   } catch (e) {
  //     console.log(e);
  //   }
  //   super.setState(state);
  // }

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

  showCompose = () => {
    this.setState({...this.state, composeVisible: true});
  }

  hideCompose = (envelope) => {
    this.setState({...this.state, composeVisible: false});
  }

  render() {
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
        />
        <button className="compose-button" onClick={this.showCompose}>New Email</button>
        <div
          className={`compose-blackout ${this.state.composeVisible ? 'show-compose' : 'hide-compose'}`}
          id="compose-blackout"
        >
          <div
            className={`compose-wrapper ${this.state.composeVisible ? 'show-compose' : 'hide-compose'}`}
            id="compose-wrapper"
          >
          <ComposeOverlay
              token={this.props.token}
              api_url={this.props.api_url}
              host={this.props.host}
              smtp_host={this.props.smtp_host}
              hide={this.hideCompose}
              domains={this.props.domains}
              setMessage={this.props.setMessage}
              quotedMessage=""
            />
          </div>
        </div>
      </div>
    );
  }
}

export default Email;