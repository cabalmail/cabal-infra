import React from 'react';
import axios from 'axios';

/**
 * Fetches message for current users/mailbox and displays them
 */

 
class Messages extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      messages: [],
      folder_data: []
    };
  }

  componentDidMount() {
    const response = this.getList();
    response.then(data => {
      this.setState({
        messages: data.data.data.message_data,
        folder_data: data.data.data.folder_data
      });
    });
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.mailbox !== provProps.mailbox) {
      const response = this.getList();
      response.then(data => {
        this.setState({
          messages: data.data.data.message_data,
          folder_data: data.data.data.folder_data
        });
      });
    }
  }

  getList = async (e) => {
    const response = await axios.post('/list_messages',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        mailbox: this.props.mailbox
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

  render() {
    const message_list = this.state.messages.map(item => {
      return (
        <li key={item.id} className="message-row">
          <span className="message-from">{item.from[0]}</span>
          <span className="message-date">{item.date}</span>
          <span className="message-subject">{item.subject}</span>
        </li>
      )
    })
    return (
      <div className="message-list">
        <div>Messages in {this.props.mailbox}</div>
        <ul className="message-list">{message_list}</ul>
      </div>
    );
  }
}

export default Messages;