import React from 'react';
import Envelope from './Envelope';
import ApiClient from '../../ApiClient';
import './Envelopes.css';

class Envelopes extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      envelopes: [],
      selected: null
    };
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.props.message_ids !== prevProps.message_ids) {
      const response = this.api.getEnvelopes(
        this.props.folder,
        this.props.message_ids
      );
      response.then(data => {
        this.setState({
          ...this.state,
          envelopes: data.data.envelopes
        });
      }).catch( e => {
        console.log(e);
      });
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
      <>
        {message_list}
      </>
    );
  }
}

export default Envelopes;
