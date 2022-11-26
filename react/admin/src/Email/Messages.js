/**
 * Fetches message ids for current users/mailbox and displays them
 */

import React from 'react';
import axios from 'axios';
import LazyLoad from 'react-lazyload';
import Envelopes from './Envelopes.js';

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
const PAGE_SIZE = 50;

class Messages extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      message_ids: [],
      sort_order: DESC,
      sort_field: ARRIVAL,
      loading: true
    };
  }

  componentDidMount() {
    const response = this.getList();
    response.then(data => {
      this.setState({
        message_ids: data.data.data.message_ids,
        loading: false
      });
    });
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.mailbox !== prevProps.mailbox) {
      const response = this.getList();
      response.then(data => {
        this.setState({
          message_ids: data.data.data.message_ids,
          loading: false
        });
      });
    }
  }

  getList = async (e) => {
    this.setState({loading: true})
    const response = await axios.post('/list_messages',
      JSON.stringify({
        user: this.props.userName,
        password: this.props.password,
        mailbox: this.props.mailbox,
        host: this.props.host,
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

  loadList() {
    const num_ids = this.state.message_ids.length;
    var pages = [];
    for (var i = 0; i < num_ids; i+=PAGE_SIZE) {
      pages.push(
        <LazyLoad offset={50}>
          <Envelopes
            message_ids={this.state.message_ids.slice(i, i+PAGE_SIZE)}
            userName={this.props.userName}
            password={this.props.password}
            mailbox={this.props.mailbox}
            host={this.props.host}
            token={this.props.token}
            api_url={this.props.api_url}
            showOverlay={this.props.showOverlay}
          />
        </LazyLoad>
      );
    }
    return pages;
  }

  render() {
    const list = this.loadList();
    return (
      <div className="message-list">
        <ul className={`message-list ${this.state.loading ? "loading" : ""}`}>{list}</ul>
      </div>
    );
  }
}

export default Messages;