import React from 'react';
import './Email.css';
import Messages from './Messages';
import MessageOverlay from './MessageOverlay';

class Email extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      folder: "INBOX",
      overlayVisible: false,
      envelope: {},
      flags: []
    };
  }

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
          setMessage={this.props.setMessage}
        />
      </div>
    );
  }
}

export default Email;