/**
 * Fetches message ids for current users/folder and displays them
 */

import React from 'react';
import axios from 'axios';
import LazyLoad from 'react-lazyload';
import Envelopes from './Envelopes';
import Folders from './Folders';
import { ASC, DESC, ARRIVAL, DATE, FROM, SUBJECT, PAGE_SIZE} from '../constants'

class Messages extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      message_ids: [],
      selected_messages: [],
      sort_order: DESC,
      sort_field: DATE,
      filter_state: "collapsed",
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
    if ((this.props.folder !== prevProps.folder) ||
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
        folder: this.props.folder,
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
            userName={this.props.userName}
            password={this.props.password}
            folder={this.props.folder}
            host={this.props.host}
            token={this.props.token}
            api_url={this.props.api_url}
            showOverlay={this.props.showOverlay}
            handleCheck={this.handleCheck}
            setMessage={this.props.setMessage}
          />
        </LazyLoad>
      );
    }
    return pages;
  }

  collapse = (e) => {
    e.preventDefault();
    this.setState({...this.state, filter_state: "collapsed"});
  }

  expand = (e) => {
    e.preventDefault();
    this.setState({...this.state, filter_state: "expanded"});
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
        <div className={`filter ${this.state.sort_order.css} ${this.state.filter_state}`}>
          <button
            onClick={this.collapse}
            className="filter_expand_collapse collapse_filter"
            title="Hide message header"
          >⋀</button>
          <button
            onClick={this.expand}
            className="filter_expand_collapse expand_filter"
            title="Show message header"
          >⋁</button>
          <br />
          <Folders 
            token={this.props.token}
            password={this.props.password}
            userName={this.props.userName}
            api_url={this.props.api_url}
            setFolder={this.props.setFolder}
            host={this.props.host}
            folder={this.props.folder}
            setMessage={this.props.setMessage}
          />
          <br />
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
          <div className="filter">
            <label htmlFor="action">Batch action:</label>
            <select id="action" name="action" className="action">
              <option value="noop"  ></option>
              <option value="delete">🗑️ Delete</option>
              <option value="move"  >📨 Move to...</option>
              <option value="read"  >✉️ Mark read</option>
              <option value="unread">🔵 Mark unread</option>
              <option value="flag"  >🚩 Flag</option>
            </select>
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