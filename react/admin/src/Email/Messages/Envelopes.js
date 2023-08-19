import React from 'react';
import { SwipeableList, IOS } from 'react-swipeable-list';
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

  clearArrays() {
    for (var p; p < this.page.length; p++) {
      this.page[p] = null;
    }
    for (var o; o < this.observer.length; o++) {
      this.observer[o] = null;
    }
  }

  componentDidUpdate(prevProps, prevState) {
    if (!this.arrayCompare(prevProps.message_ids, this.props.message_ids)) {
      const num_ids = this.props.message_ids.length;
      this.clearArrays();
      this.setState({...this.state, envelopes: {}});
      for (var i = 0; i < num_ids; i+=PAGE_SIZE) {
        let ids = this.props.message_ids.slice(i, i+PAGE_SIZE);
        let page = Math.floor(i/PAGE_SIZE);
        this.page[page] = () => {
          if (page > 4) {
            this.observer[page-5] = null;
          }
          this.api.getEnvelopes(this.props.folder, ids).then(data => {
          let envelopes = { ...this.state.envelopes, ...data.data.envelopes };
          this.setState({
              ...this.state,
              envelopes: envelopes
            });
          }).catch( e => {
            console.log(e);
          });
        };
      }
      switch (this.page.length) {
        case 1:
          this.page[0]();
          break;
        case 2:
          this.page[0]();
          this.page[1]();
          break;
        case 3:
          this.page[0]();
          this.page[1]();
          this.page[2]();
          break;
        case 4:
          this.page[0]();
          this.page[1]();
          this.page[2]();
          this.page[3]();
          break;
        default:
          this.page[0]();
          this.page[1]();
          this.page[2]();
          this.page[3]();
          this.page[4]()
      }
    }
  }

  componentWillUnmount() {
    this.clearArrays();
  }

  handleClick = (envelope, id) => {
    this.props.showOverlay(envelope);
    this.props.handleSelect(id);
    this.setState({...this.state, selected:id});
  }

  handleCheck = (id, checked, page) => {
    console.log(`Checkbox clicked. Handler in Envelopes class invoked. New state: ${checked}`);
    this.props.handleCheck(id, checked);
    console.log(`Reloading page ${page}`);
    this.page[page]();
  }

  markRead = (id, page) => {
    this.props.markRead(id).then(() => {
      this.page[page]();
    });
  }

  markUnread = (id, page) => {
    this.props.markUnread(id).then(() => {
      this.page[page]();
    });
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
      let first_of_page = false;
      const page = Math.floor(i/PAGE_SIZE);
      if (i % PAGE_SIZE === 0) {
        if (page < this.page.length -5) {
          setTimeout(() => {
            const options = {
              root: null,
              rootMargin: "0px",
              theshold: 0.1
            };
            this.observer[page] = new IntersectionObserver(this.page[page+5], options);
            this.observer[page].observe(document.getElementById(e.id.toString()));
          }, 1000);
        }
        first_of_page = true;
      }
      return (
        <Envelope
          handleClick={this.handleClick}
          handleCheck={this.handleCheck}
          archive={this.archive}
          markRead={this.markRead}
          markUnread={this.markUnread}
          envelope={e}
          is_checked={this.props.selected_messages.includes(parseInt(e.id))}
          dom_id={e.id}
          page={page}
          first_of_page={first_of_page}
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
