/**
 * Fetches message for current users/mailbox and displays them
 */

import React from 'react';
import axios from 'axios';

// see https://www.rfc-editor.org/rfc/rfc5256.html
// Not implemented:
//  - CC
//  - SIZE
//  - multiple simultaneous criteria such as combined subject and date
const ASC = {
  imap: "",
  description: "Ascending order (smallest/first to largest/last)"
};
const DESC = {
  imap: "REVERSE ",
  description: "Descending order (largest/last to smallest/first)"
};
const ARRIVAL = {
  imap: "ARRIVAL",
  description: "Date Received"
};
const FROM = {
  imap: "FROM",
  description: "From address"
};
const SUBJECT = {
  imap: "SUBJECT",
  description: "Subject"
};
const TO = {
  imap: "TO",
  description: "Recipient"
};

class Messages extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      message_ids: [],
      envelopes: {},
      folder_data: [],
      page: 0,
      sort_order: DESC,
      sort_field: ARRIVAL
    };
  }

  componentDidMount() {
    const response = this.getList();
    response.then(data => {
      console.log(data.data.data.envelopes);
      this.setState({
        envelopes: data.data.data.envelopes,
        message_ids: data.data.data.message_ids,
        folder_data: data.data.data.folder_data
      });
    });
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.mailbox !== prevProps.mailbox) {
      const response = this.getList();
      response.then(data => {
        console.log(data.data.data.envelopes);
        this.setState({
          envelopes: data.data.data.envelopes,
          message_ids: data.data.data.message_ids,
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
        mailbox: this.props.mailbox,
        sort_order: this.state.sort_order.imap,
        sort_field: this.state.sort_field.imap
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

  toggleOrder() {
    this.setState({
      sort_order: this.state.sort_order.imap === ASC.imap ? DESC : ASC
    })
  }

  setSortField(field) {
    switch(field) {
      case SUBJECT.imap:
        this.setState({sort_order: SUBJECT});
        break;
      case ARRIVAL.imap:
        this.setState({sort_order: ARRIVAL});
        break;
      case TO.imap:
        this.setState({sort_order: TO});
        break;
      case FROM.imap:
        this.setState({sort_order: FROM});
        break;
      default:
        this.setState({sort_order: ARRIVAL});
    }
  }

  render() {
    const message_list = this.state.message_ids.map(item => {
      if (item.id in this.state.envelopes) {
        const message = this.state.envelopes[item.id];
        return (
          <li key={item.id} className="message-row">
            <span className="message-from">{message.from[0]}</span>
            <span className="message-date">{message.date}</span>
            <span className="message-subject">{message.subject}</span>
          </li>
        );
      }
      return (
        <li key={item.id} className="message-row loading">
          <span className="message-from"></span>
          <span className="message-date"></span>
          <span className="message-subject"></span>
        </li>
      );
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