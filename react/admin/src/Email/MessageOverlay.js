import React from 'react';
import axios from 'axios';

class MessageOverlay extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      message_raw: "",
      message_body: ""
    }
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.envelope.id !== prevProps.envelope.id) {
      const response = this.getMessage();
      response.then(data => {
        this.setState({
          message_raw: data.data.data.message_raw,
          message_body: data.data.data.message_body
        });
        console.log(data);
      });
    }
  }

  getMessage = async (e) => {
    const response = await axios.post('/fetch_message',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        mailbox: this.props.mailbox,
        id: this.props.envelope.id
      }),
      {
        baseURL: this.props.api_url,
        headers: {
          'Authorization': this.props.token
        },
        timeout: 10000
      }
    );
    return response;
  }

  hide = (e) => {
    e.preventDefault();
    this.props.hide();
  }

  render() {
    if (this.props.visible) {
      console.log(this.props.envelope.struct);
      return (
        <div className="message_overlay">
          <button onClick={this.hide} className="close_overlay">❌</button>
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
          <hr />
          <div className="message_raw">{this.state.message_raw}</div>
          <hr />
          <div className="message_body">{this.state.message_body}</div>
        </div>
      );
    }
    return <div className="message_overlay overlay_hidden"></div>;
  }
}

export default MessageOverlay;
