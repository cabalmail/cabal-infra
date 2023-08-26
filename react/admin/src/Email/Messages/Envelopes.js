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

  loadPage = (pages) => {
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
          this.loadPage([page]);
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

  // componentWillUnmount() {
  //   this.clearPages();
  // }

  handleClick = (envelope, id) => {
    this.props.showOverlay(envelope);
    this.props.handleSelect(id);
    this.setState({...this.state, selected:id});
  }

  handleCheck = (id, checked) => {
    this.props.handleCheck(id, checked);
  }

  markRead = (id, page) => {
    this.props.markRead(id).then(() => {
      this.loadPage([page]);
    });
  }

  markUnread = (id, page) => {
    this.props.markUnread(id).then(() => {
      this.loadPage([page]);
    });
  }

  archive = (id) => {
    this.props.archive(id);
  }

  // buildList() {
  //   return this.props.message_ids.filter(k => {
  //     return this.state.envelopes.hasOwnProperty(k.toString());
  //   }).map(k => {
  //     return this.state.envelopes[k.toString()];
  //   });
  // }

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
            pageLoader={this.loadPage}
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
