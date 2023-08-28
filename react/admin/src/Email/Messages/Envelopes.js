import React from 'react';
import Observer from './Observer';
import { SwipeableList, IOS } from 'react-swipeable-list';
import 'react-swipeable-list/dist/styles.css';
import Envelope from './Envelope';
import ApiClient from '../../ApiClient';
import { PAGE_SIZE } from '../../constants';
import './Envelopes.css';

class Envelopes extends React.Component {

  constructor(props) {
    super(props);
    this.pages = [];
    this.state = {
      envelopes: {},
      pages: [],
      selected: null // do we need this?
    };
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  loadPages = (pages) => {
    for(const page of pages) {
      let envelopes = { ...this.state.envelopes, ...this.state.pages[page] };
      this.setState({
        ...this.state,
        envelopes: envelopes
      });
    }
  }

  arrayCompare(array1, array2) {
    const len = array1.length;
    if (len !== array2.length) {
      return false;
    }
    for (var i = 0; i < len; i++) {
      if (array1[i] !== array2[i]) {
        return false;
      }
    }
    return true;
  }

  clearPages() {
    for (var p; p < this.pages.length; p++) {
      this.pages[p] = null;
    }
  }

  shouldComponentUpdate(_next_props, next_state) {
    return next_state.pages.length > 0;
  }

  doUpdate() {
    this.clearPages();
    const num_ids = this.props.message_ids.length;
    this.setState({...this.state, envelopes: {}});
    for (var i = 0; i < num_ids; i+=PAGE_SIZE) {
      let ids = this.props.message_ids.slice(i, i+PAGE_SIZE);
      let page = Math.floor(i/PAGE_SIZE);
      this.api.getEnvelopes(this.props.folder, ids).then(data => {
        let pages = this.state.pages.slice();
        pages[page] = data.data.envelopes;
        this.setState({
          ...this.state,
          pages: pages
        });
        if (page < 4) {
          this.loadPages([page]);
        }
      }).catch( e => {
        console.log(e);
      });
    }
  }

  componentDidMount() {
    this.doUpdate();
  }

  componentDidUpdate(prevProps, _prevState) {
    if (!this.arrayCompare(prevProps.message_ids, this.props.message_ids)) {
      this.doUpdate();
    }
  }

  handleClick = (envelope, id) => {
    this.props.showOverlay(envelope);
    this.props.handleSelect(id);
    this.setState({...this.state, selected:id});
  }

  handleCheck = (id, checked) => {
    this.props.handleCheck(id, checked);
  }

  markRead = (id, page) => {
    let envelopes = JSON.parse(JSON.stringify(this.state.envelopes));
    envelopes[id.toString()].flags.push("\\Seen");
    this.setState({ ...this.state, envelopes: envelopes });
    this.props.markRead(id);
  }

  markUnread = (id, page) => {
    let envelopes = JSON.parse(JSON.stringify(this.state.envelopes));
    let envelope = envelopes[id.toString()]
    envelope.flags.splice(envelope.flags.indexOf("\\Seen"),1);
    envelopes[id.toString()] = envelope;
    this.setState({ ...this.state, envelopes: envelopes });
    this.props.markUnread(id);
  }

  archive = (id) => {
    this.props.archive(id);
  }

  render() {
    let i = 0;
    const message_list = this.props.message_ids.filter(k => {
      return this.state.envelopes.hasOwnProperty(k.toString());
    }).map(k => {
      return this.state.envelopes[k.toString()];
    }).map(e => {
      let first_of_page = false;
      let observer = <></>;
      const page = Math.floor(i/PAGE_SIZE);
      if (i % PAGE_SIZE === 0) {
        first_of_page = true;
        observer = (
          <Observer
            pageLoader={this.loadPages}
            page={page+2}
            key={page+2}
          ></Observer>
        );
      } else {
        observer = null;
      }
      i++;
      return (
        <Envelope
          handleClick={this.handleClick}
          handleCheck={this.handleCheck}
          archive={this.archive}
          markRead={this.markRead}
          markUnread={this.markUnread}
          envelope={e}
          subject={e.subject}
          priority={e.priority}
          date={e.date}
          from={e.from}
          to={e.to}
          cc={e.cc}
          flags={e.flags}
          struct={e.struct}
          is_checked={this.props.selected_messages.includes(parseInt(e.id))}
          dom_id={e.id}
          page={page}
          first_of_page={first_of_page}
          observer={observer}
          key={e.id}
        />
      );
    });
    return (
      <SwipeableList
        fullSwipe={true}
        type={IOS}
        className={`message-list ${this.state.loading ? "loading" : ""}`}
      >
        {message_list}
      </SwipeableList>
    );
  }
}

export default Envelopes;
