/**
 * Fetches message ids for current users/folder and displays them
 */

import React from 'react';
import axios from 'axios';
import LazyLoad from 'react-lazyload';
import Envelopes from './Envelopes';
import Folders from './Folders';
import { ASC, DESC, ARRIVAL, DATE, FROM, SUBJECT, PAGE_SIZE,
         READ, UNREAD, FLAGGED, UNFLAGGED } from '../constants'

import './Messages.css';

class Messages extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      message_ids: [],
      selected_messages: [],
      sort_order: DESC,
      sort_field: DATE,
      loading: true
    };
  }

  componentDidMount() {
    this.poller();
    this.interval = setInterval(this.poller, 10000);
  }

  componentDidUpdate(prevProps, prevState) {
    if ((this.props.folder !== prevProps.folder) ||
        (this.state.sort_order !== prevState.sort_order) ||
        (this.state.sort_field !== prevState.sort_field)) {
      this.poller();
    }
  }

  componentWillUnmount() {
    clearInterval(this.interval);
  }

  poller = () => {
    const response = this.getList();
    response.then(data => {
      this.setState({
        ...this.state,
        message_ids: data.data.message_ids,
        loading: false
      }).catch(e => {
        this.props.setMessage("Unable to get list of messages.", true);
        console.log(e);
      });
    });
  }

  getList = (e) => {
    this.setState({...this.state, loading: true})
    const response = axios.get('/list_messages',
      {
        params: {
          folder: this.props.folder,
          host: this.props.host,
          sort_order: this.state.sort_order.imap,
          sort_field: this.state.sort_field.imap
        },
        baseURL: this.props.api_url,
        headers: {
          'Authorization': this.props.token
        },
        timeout: 8000
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

  setFlag = (flag, op) => {
    const response = axios.put('/set_flag',
      JSON.stringify({
        host: this.props.host,
        folder: this.props.folder,
        ids: this.state.selected_messages,
        flag: flag,
        op: op,
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

  handleActionButtonClick = (e) => {
    e.stopPropagation();
    var action = e.target.id;
    if (e.target.tagName !== 'BUTTON') {
      action = e.target.parentElement.id;
    }
    var callback = (data) => {
      this.setState({
        ...this.state,
        message_ids: data.data.message_ids,
        selected_messages: [],
        loading: false
      });
      this.props.setMessage("Flag set.", false);
    };
    var catchback = (err) => {
      this.props.setMessage(`Unable to set flag "${action}" on selected messages.`, true);
      console.log(`Unable to set flag "${action}" on selected messages.`);
      console.log(err);
    };
    switch (action) {
      case "delete":
        this.props.setMessage("Deletion isn't implemented yet.", true);
        break;
      case "move":
        this.props.setMessage("Moving messages isn't implamented yet.", true);
        break;
      case READ.css:
        this.setFlag(READ.imap, READ.op).then(callback).catch(catchback);
        break;
      case UNREAD.css:
        this.setFlag(UNREAD.imap, UNREAD.op).then(callback).catch(catchback);
        break;
      case FLAGGED.css:
        this.setFlag(FLAGGED.imap, FLAGGED.op).then(callback).catch(catchback);
        break;
      case UNFLAGGED.css:
        this.setFlag(UNFLAGGED.imap, UNFLAGGED.op).then(callback).catch(catchback);
        break;
      default:
        console.log(`"${action}" clicked`);
    }
  }

  handleCheck = (message_id, checked) => {
    var id = parseInt(message_id);
    if (checked) {
      this.setState({
        ...this.state,
        selected_messages: [...this.state.selected_messages, id]
      });
    } else {
      this.setState({
        ...this.state,
        selected_messages: this.state.selected_messages.filter(function(i) { 
          return id !== i;
        })
      });
    }
  }

  loadList() {
    const num_ids = this.state.message_ids.length;
    var pages = [];
    for (var i = 0; i < num_ids; i+=PAGE_SIZE) {
      pages.push(
        <LazyLoad offset={150} overflow={true}>
          <Envelopes
            message_ids={this.state.message_ids.slice(i, i+PAGE_SIZE)}
            folder={this.props.folder}
            host={this.props.host}
            token={this.props.token}
            api_url={this.props.api_url}
            selected_messages={this.state.selected_messages}
            showOverlay={this.props.showOverlay}
            handleCheck={this.handleCheck}
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
      case DATE.imap:
        this.setState({...this.state, sort_field: DATE, loading: true});
        break;
      case ARRIVAL.imap:
        this.setState({...this.state, sort_field: ARRIVAL, loading: true});
        break;
      case FROM.imap:
        this.setState({...this.state, sort_field: FROM, loading: true});
        break;
      default:
        this.setState({...this.state, sort_field: DATE, loading: true});
    }
  }

  render() {
    const list = this.loadList();
    // TO field omitted since it's not displayed
    const options = [DATE, ARRIVAL, SUBJECT, FROM].map(i => {
      return <option id={i.css} value={i.imap}>{i.description}</option>;
    });
    return (
      <div className="email_list">
        <div className={`filters ${this.state.sort_order.css}`}>
          <Folders 
            token={this.props.token}
            api_url={this.props.api_url}
            setFolder={this.props.setFolder}
            host={this.props.host}
            folder={this.props.folder}
            setMessage={this.props.setMessage}
          />&nbsp;
          <div className="filter">
            <label htmlFor="sort-field">Sort by:</label>
            <select id="sort-by" name="sort-by" className="sort-by" onChange={this.setSortField}>
              {options}
            </select>
            <button
              id={ASC.css}
              className="sort-order"
              title="Sort ascending"
              onClick={this.sortAscending}
            >⩓</button>
            <button
              id={DESC.css}
              className="sort-order"
              title="Sort descending"
              onClick={this.sortDescending}
            >⩔</button>
          </div>
          <br />
          <div className="filter filter-actions">
            <button
              value="delete"
              id="delete"
              name="delete"
              className="action delete"
              title="Delete"
              onClick={this.handleActionButtonClick}
            >🗑️<span className="wide-screen"> Delete</span></button>
            <button
              value="move"
              id="move"
              name="move"
              className="action move"
              title="Move to..."
              onClick={this.handleActionButtonClick}
            >📨<span className="wide-screen"> Move to...</span></button>
            <button
              value={READ.css}
              id={READ.css}
              name={READ.css}
              className={`action ${READ.css}`}
              title={READ.description}
              onClick={this.handleActionButtonClick}
            >{READ.icon}<span className="wide-screen"> {READ.description}</span></button>
            <button
              value={UNREAD.css}
              id={UNREAD.css}
              name={UNREAD.css}
              className={`action ${UNREAD.css}`}
              title={UNREAD.description}
              onClick={this.handleActionButtonClick}
            >{UNREAD.icon}<span className="wide-screen"> {UNREAD.description}</span></button>
            <button
              value={FLAGGED.css}
              id={FLAGGED.css}
              name={FLAGGED.css}
              className={`action ${FLAGGED.css}`}
              title={FLAGGED.description}
              onClick={this.handleActionButtonClick}
            >{FLAGGED.icon}<span className="wide-screen"> {FLAGGED.description}</span></button>
              <button
              value={UNFLAGGED.css}
              id={UNFLAGGED.css}
              name={UNFLAGGED.css}
              className={`action ${UNFLAGGED.css}`}
              title={UNFLAGGED.description}
              onClick={this.handleActionButtonClick}
            >{UNFLAGGED.icon}<span className="wide-screen"> {UNFLAGGED.description}</span></button>
          </div>
        </div>
        <ul className={`message-list ${this.state.loading ? "loading" : ""}`}>
          {list}
        </ul>
      </div>
    );
  }
}

export default Messages;