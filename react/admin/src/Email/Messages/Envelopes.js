import React from 'react';
import { SwipeableList } from 'react-swipeable-list';
import 'react-swipeable-list/dist/styles.css';
import Envelope from './Envelope';
import ApiClient from '../../ApiClient';
import { PAGE_SIZE } from '../../constants';
import './Envelopes.css';

class Envelopes extends React.Component {

  constructor(props) {
    super(props);
    this.page = [];
    this.observer =[];
    this.state = {
      envelopes: {},
      selected: null // do we need this?
    };
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
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

  componentDidUpdate(prevProps, prevState) {
    if (!this.arrayCompare(prevProps.message_ids, this.props.message_ids)) {
      const num_ids = this.props.message_ids.length;
      for (const p of this.page) {
        p = null;
      }
      this.setState({...this.state, envelopes: {}});
      console.log("Update");
      console.log(`message_ids is ${this.props.message_ids.length} long`);
      console.log(`PAGE_SIZE is ${PAGE_SIZE}`);
      for (var i = 0; i < num_ids; i+=PAGE_SIZE) {
        console.log(i);
        let ids = this.props.message_ids.slice(i, i+PAGE_SIZE);
        let page = i/PAGE_SIZE;
        this.page[page] = () => {
          console.log(`Loading page ${page}`);
          const response = this.api.getEnvelopes(this.props.folder, ids);
          response.then(data => {
          let envelopes = { ...this.state.envelopes, ...data.data.envelopes };
          this.setState({
              ...this.state,
              envelopes: envelopes
            });
            console.log(this.state.envelopes);
          }).catch( e => {
            console.log(e);
          });
        };
      }
    }
  }

  componentWillUnmount() {
    for (const p of this.page) {
      p = null;
    }
    for (const o of this.observer) {
      o = null;
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

  markRead = (id) => {
    this.props.markRead(id);
  }

  markUnread = (id) => {
    this.props.markUnread(id);
  }

  archive = (id) => {
    this.props.archive(id);
  }

  buildList() {
    return this.props.message_ids.filter(k => {
      return this.state.envelopes.hasOwnProperty(k.toString());
    }).map(k => {
      return this.state.envelopes[k.toString()];
    });
  }

  render() {
    let i = -1;
    const message_list = this.buildList().map(e => {
      i++;
      const page = i/PAGE_SIZE;
      if (i % PAGE_SIZE === 0) {
        if (page < this.page.length -1) {
          setTimeout(() => {
            const options = {
              root: null,
              rootMargin: "0px",
              theshold: 0.1
            };
            this.observer[page] = new IntersectionObserver(this.page[page+1], options);
            this.observer[page].observe(document.getElementById(e.id.toString()));
          }, 100);
        }
        return (
          <Envelope
            handleClick={this.handleClick}
            handleCheck={this.handleCheck}
            archive={this.archive}
            markRead={this.markRead}
            markUnread={this.markUnread}
            envelope={e}
            checked={this.props.selected_messages.includes(e.id)}
            id={e.id}
            key={e.id}
          />
        );
      }
      return (
        <Envelope
          handleClick={this.handleClick}
          handleCheck={this.handleCheck}
          archive={this.archive}
          markRead={this.markRead}
          markUnread={this.markUnread}
          envelope={e}
          checked={this.props.selected_messages.includes(e.id)}
          key={e.id}
        />
      );
    });
    return (
      <SwipeableList
        fullSwipe={true}
        type="IOS"
        className={`message-list ${this.state.loading ? "loading" : ""}`}
      >
        {message_list}
      </SwipeableList>
    );
  }
}

export default Envelopes;
