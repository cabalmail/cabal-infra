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
        ...this.state,
        message_ids: data.data.data.message_ids,
        loading: false
      }).catch(e => {
        this.props.setMessage("Unable to get list of messages.");
        console.log(e);
      });
    });
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.mailbox !== prevProps.mailbox) {
      const response = this.getList();
      response.then(data => {
        this.setState({
          ...this.state,
          message_ids: data.data.data.message_ids,
          loading: false
        });
      }).catch(e => {
        this.props.setMessage("Unable to get list of messages.");
        console.log(e);
      });
    }
  }

  getList = async (e) => {
    this.setState({...this.state, loading: true})
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
      ...this.state,
      sort_order: this.state.sort_order.imap === ASC.imap ? DESC : ASC
    })
  }

  setSortField(field) {
    switch(field) {
      case SUBJECT.imap:
        this.setState({...this.state, sort_order: SUBJECT});
        break;
      case ARRIVAL.imap:
        this.setState({...this.state, sort_order: ARRIVAL});
        break;
      case TO.imap:
        this.setState({...this.state, sort_order: TO});
        break;
      case FROM.imap:
        this.setState({...this.state, sort_order: FROM});
        break;
      default:
        this.setState({...this.state, sort_order: ARRIVAL});
    }
  }

  handleSubmit = (e) => {
    e.preventDefault();
    console.log("not implemented");
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
            setMessage={this.props.setMessage}
          />
        </LazyLoad>
      );
    }
    return pages;
  }

  render() {
    const list = this.loadList();
    const options = [ARRIVAL, SUBJECT, TO, FROM].map(i => {
      return <option id={i.imap} value={i.imap}>{i.description}</option>;
    });
    return (
      <form className="message-list" onSubmit={this.handleSubmit}>
        <div className="filter">
          <button id="asc" className="sort-order" title="Sort ascending">⩓</button>
          <button id="desc" className="sort-order" title="Sort descending">⩔</button>
          <span>
            <label htmlFor="sort-field">Sort by:</label>
            <select id="sort-by" name="sort-by">
              {options}
            </select>
          </span>
        </div>
        <ul className={`message-list ${this.state.loading ? "loading" : ""}`}>{list}</ul>
      </form>
    );
  }
}

export default Messages;