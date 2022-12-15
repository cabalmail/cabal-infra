/**
 * Fetches message ids for current users/mailbox and displays them
 */

import React from 'react';
import axios from 'axios';
import LazyLoad from 'react-lazyload';
import Envelopes from './Envelopes';
import Mailboxes from './Mailboxes';
import { ASC, DESC, ARRIVAL, FROM, SUBJECT, PAGE_SIZE} from '../constants'

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
        message_ids: data.data.message_ids,
        loading: false
      }).catch(e => {
        this.props.setMessage("Unable to get list of messages.");
        console.log(e);
      });
    });
  }

  componentDidUpdate(prevProps, prevState) {
    if ((this.props.mailbox !== prevProps.mailbox) ||
      (this.state.sort_order !== prevState.sort_order) ||
      (this.state.sort_field !== prevState.sort_field)) {
      const response = this.getList();
      this.setState({...this.state, loading: true});
      response.then(data => {
        this.setState({
          ...this.state,
          message_ids: data.data.message_ids,
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

  loadList() {
    const num_ids = this.state.message_ids.length;
    var pages = [];
    for (var i = 0; i < num_ids; i+=PAGE_SIZE) {
      pages.push(
        <LazyLoad offset={PAGE_SIZE}>
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

  sortAscending = (e) => {
    e.preventDefault();
    this.setState({...this.state, sort_order: ASC, loading: true});
  }

  sortDescending = (e) => {
    e.preventDefault();
    this.setState({...this.state, sort_order: DESC, loading: true});
  }

  setSortField = (e) => {
    e.preventDefault();
    switch(e.target.value) {
      case SUBJECT.imap:
        this.setState({...this.state, sort_field: SUBJECT, loading: true});
        break;
      case ARRIVAL.imap:
        this.setState({...this.state, sort_field: ARRIVAL, loading: true});
        break;
      case FROM.imap:
        this.setState({...this.state, sort_field: FROM, loading: true});
        break;
      default:
        this.setState({...this.state, sort_field: ARRIVAL, loading: true});
    }
  }

  render() {
    const list = this.loadList();
    // TO field omitted since it's not displayed
    const options = [ARRIVAL, SUBJECT, FROM].map(i => {
      return <option id={i.css} value={i.imap}>{i.description}</option>;
    });
    return (
      <>
        <div className={`filter ${this.state.sort_order.css}`}>
          <Mailboxes 
            token={this.props.token}
            password={this.props.password}
            userName={this.props.userName}
            api_url={this.props.api_url}
            setMailbox={this.props.setMailbox}
            host={this.props.host}
            mailbox={this.props.mailbox}
            setMessage={this.props.setMessage}
          />
          <span>
            <button
              id="asc"
              className="sort-order"
              title="Sort ascending"
              onClick={this.sortAscending}
            >⩓</button>
            <button
              id="desc"
              className="sort-order"
              title="Sort descending"
              onClick={this.sortDescending}
            >⩔</button>
          </span>
          <span>
            <label htmlFor="sort-field">Sort by:</label>
            <select id="sort-by" name="sort-by" onChange={this.setSortField}>
              {options}
            </select>
          </span>
        </div>
        <ul className={`message-list ${this.state.loading ? "loading" : ""}`}>
          {list}
        </ul>
      </>
    );
  }
}

export default Messages;