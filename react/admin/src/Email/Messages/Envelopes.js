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
    this.state = {
      envelopes: [],
      selected: null // do we need this?
    };
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  componentDidMount() {
    const num_ids = this.props.message_ids.length;
    console.log("Mounted");
    for (var i = 0; i < num_ids; i+=PAGE_SIZE) {
      console.log(i);
      let ids = this.props.message_ids.slice(i, i+PAGE_SIZE);
      setInterval(() => {
        console.log(`Loading page ${i/PAGE_SIZE}`);
        const response = this.api.getEnvelopes(this.props.folder, ids);
        response.then(data => {
          let envelopes = this.state.envelopes.slice();
          envelopes.concat(data.data.envelopes);
          this.setState({
            ...this.state,
            envelopes: envelopes
          });
        }).catch( e => {
          console.log(e);
        });
      }, 1000 * i + 10);
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

  render() {
    var i = 0;
    const message_list = this.state.envelopes.map(e => {
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
          index={i}
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
