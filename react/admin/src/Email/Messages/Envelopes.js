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

  componentDidUpdate(prevProps, prevState) {
    if (this.props.message_ids !== prevProps.message_ids) {



      const num_ids = this.props.message_ids.length;
      for (var i = 0; i < num_ids; i+=PAGE_SIZE) {
        let ids = this.props.message_ids.slice(i, i+PAGE_SIZE);

        setInterval(() => {

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

        }, 1000 * (i));

      }



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
  // loadList() {
  //   const num_ids = this.state.message_ids.length;
  //   var pages = [];
  //   for (var i = 0; i < num_ids; i+=PAGE_SIZE) {
  //     pages.push(
  //       <LazyLoad offset={150} overflow={true}>
  //         <Envelopes
  //           message_ids={this.state.message_ids.slice(i, i+PAGE_SIZE)}
  //           folder={this.props.folder}
  //           host={this.props.host}
  //           token={this.props.token}
  //           api_url={this.props.api_url}
  //           selected_messages={this.state.selected_messages}
  //           showOverlay={this.props.showOverlay}
  //           handleCheck={this.handleCheck}
  //           handleSelect={this.handleSelect}
  //           setMessage={this.props.setMessage}
  //           markUnread={this.markUnread}
  //           markRead={this.markRead}
  //           archive={this.archive}
  //         />
  //       </LazyLoad>
  //     );
  //   }
  //   return pages;
  // }

  render() {
    var i = 0;
    const message_list = this.props.message_ids.map(id => {
      if (id.toString() in this.state.envelopes) {
        return (
          <Envelope
            handleClick={this.handleClick}
            handleCheck={this.handleCheck}
            archive={this.archive}
            markRead={this.markRead}
            markUnread={this.markUnread}
            envelope={this.state.envelopes[id]}
            checked={this.props.selected_messages.includes(id)}
            id={id}
            index={i}
          />
        );
      }
      return (
        <div className="message-row loading" key={id}>
          <div className="message-line-1">
            <div className="message-field message-from">&nbsp;</div>
            <div className="message-field message-date">&nbsp;</div>
          </div>
          <div className="message-field message-subject">&nbsp;</div>
        </div>
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
