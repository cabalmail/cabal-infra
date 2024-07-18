/**
 * Fetches message ids for current users/folder and displays them
 */

import React from 'react';
import ApiClient from '../../ApiClient';
// import LazyLoad from 'react-lazyload';
import Envelopes from './Envelopes';
import Folders from './Folders';
import Actions from '../Actions';
import { READ, UNREAD, ASC, DESC, ARRIVAL, DATE, FROM, SUBJECT } from '../../constants';
import './Messages.css';

class Messages extends React.Component {

  constructor(props) {
    super(props);
    this.callbackTimeout = null;
    this.poller1Timeout = null;
    this.poller2Timeout = null;
    this.archiveTimeout = null;
    this.interval = null;
    this.state = {
      message_ids: [],
      shown_message: null,
      selected_messages: [],
      sort_order: DESC,
      sort_field: DATE,
      loading: true
    };
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  componentDidMount() {
    this.poller(
      this.api,
      this.props.folder,
      this.state.sort_order.imap,
      this.state.sort_field.imap,
      this
    );
    this.poller1Timeout = setTimeout(
      this.poller,
      10, 
      this.api,
      this.props.folder,
      this.state.sort_order.imap,
      this.state.sort_field.imap,
      this
    );
    this.interval = setInterval(
      this.poller,
      10000, 
      this.api,
      this.props.folder,
      this.state.sort_order.imap,
      this.state.sort_field.imap,
      this
    );
  }

  componentDidUpdate(prevProps, prevState) {
    if ((this.props.folder !== prevProps.folder) ||
        (this.state.sort_order !== prevState.sort_order) ||
        (this.state.sort_field !== prevState.sort_field)) {
      clearInterval(this.interval);
      this.poller(
        this.api,
        this.props.folder,
        this.state.sort_order.imap,
        this.state.sort_field.imap,
        this
      );
      this.poller2Timeout = setTimeout(
        this.poller,
        10, 
        this.api,
        this.props.folder,
        this.state.sort_order.imap,
        this.state.sort_field.imap,
        this
      );
      clearInterval(this.interval);
      this.interval = setInterval(
        this.poller,
        10000, 
        this.api,
        this.props.folder,
        this.state.sort_order.imap,
        this.state.sort_field.imap,
        this
      );
    }
  }

  componentWillUnmount() {
    clearInterval(this.interval);
    clearTimeout(this.callbackTimeout);
    clearTimeout(this.poller1Timeout);
    clearTimeout(this.poller2Timeout);
    clearTimeout(this.archiveTimeout);
  }

  poller(api, folder, order, field, that) {
    const response = api.getMessages(folder, order, field);
    response.then(data => {
      that.setState({
        ...that.state,
        message_ids: data.data.message_ids,
        loading: false
      });
    }).catch(e => {
      that.props.setMessage("Unable to get list of messages.", true);
      console.log(e);
    });
  }

  toggleOrder() {
    this.setState({
      ...this.state,
      sort_order: this.state.sort_order.imap === ASC.imap ? DESC : ASC
    })
  }

  callback = (data) => {
    this.setState({
      ...this.state,
      message_ids: [],
      loading: true
    });
    this.callbackTimeout = setTimeout(() => {
      this.setState({
        ...this.state,
        message_ids: data.data.message_ids,
        loading: false
      });
    }, 1);
  }

  catchback = (err) => {
    this.props.setMessage(`Unable to set flag on selected messages.`, true);
    console.log(`Unable to set flag on selected messages.`);
    console.error(err);
  };

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

  handleSelect = (message_id) => {
    var id = parseInt(message_id);
    this.setState({
      ...this.state,
      selected_message: id
    });
  }

  archive = (message_id) => {
    this.api.setFlag(
      this.props.folder,
      READ.imap,
      READ.op,
      [message_id],
      this.state.sort_order.imap,
      this.state.sort_field.imap
    ).then(() => {
      this.archiveTimeout = setTimeout(() => {
        this.api.moveMessages(
          this.props.folder,
          'Archive',
          [message_id],
          this.state.sort_order.imap,
          this.state.sort_field.imap
        );
      }, 500);
    });
  }

  markRead = (message_id) => {
    return this.api.setFlag(
      this.props.folder,
      READ.imap,
      READ.op,
      [message_id],
      this.state.sort_order.imap,
      this.state.sort_field.imap
    );
  }

  markUnread = (message_id) => {
    return this.api.setFlag(
      this.props.folder,
      UNREAD.imap,
      UNREAD.op,
      [message_id],
      this.state.sort_order.imap,
      this.state.sort_field.imap
    );
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

  setFolder = (folder) => {
    this.setState({...this.state, selected_messages: []});
    this.props.setFolder(folder);
  }

  render() {
    // TO field omitted since it's not displayed
    const options = [DATE, ARRIVAL, SUBJECT, FROM].map(i => {
      return <option id={i.css} value={i.imap} key={i.imap}>{i.description}</option>;
    });
    const selected = this.state.selected_messages.length ? " selected" : " none_selected";
    if (this.state.loading) {
      return <div className="email_list loading">Loading...</div>;
    }
    return (
      <div className="email_list">
        <div className="sticky">
          <div className={`filters filters-dropdowns ${this.state.sort_order.css}`}>
            <Folders 
              token={this.props.token}
              api_url={this.props.api_url}
              setFolder={this.setFolder}
              host={this.props.host}
              folder={this.props.folder}
              setMessage={this.props.setMessage}
              label="Folder"
            />&nbsp;
            <div>
              <span className="filter filter-sort">
                <label htmlFor="sort-field">Sort by:</label>
                <select id="sort-by" name="sort-by" className="sort-by" onChange={this.setSortField}>
                  {options}
                </select>
                <button
                  id={ASC.css}
                  className="sort-order"
                  title="Sort ascending"
                  onClick={this.sortAscending}
                >&nbsp;
                  <hr className="long first" />
                  <hr className="medium second" />
                  <hr className="short third" />
                </button>
                <button
                  id={DESC.css}
                  className="sort-order"
                  title="Sort descending"
                  onClick={this.sortDescending}
                >&nbsp;
                  <hr className="short first" />
                  <hr className="medium second" />
                  <hr className="long third" />
                </button>
              </span>
            </div>
          </div>
          <Actions
            token={this.props.token}
            api_url={this.props.api_url}
            host={this.props.host}
            folder={this.props.folder}
            selected_messages={this.state.selected_messages}
            selected={selected}
            order={this.state.sort_order.imap}
            field={this.state.sort_field.imap}
            callback={this.callback}
            catchback={this.catchback}
            setMessage={this.props.setMessage}
          />
        </div>
        <Envelopes
          message_ids={this.state.message_ids}
          folder={this.props.folder}
          host={this.props.host}
          token={this.props.token}
          api_url={this.props.api_url}
          selected_messages={this.state.selected_messages}
          showOverlay={this.props.showOverlay}
          handleCheck={this.handleCheck}
          handleSelect={this.handleSelect}
          setMessage={this.props.setMessage}
          markUnread={this.markUnread}
          markRead={this.markRead}
          archive={this.archive}
        />
      </div>
    );
  }
}

export default Messages;