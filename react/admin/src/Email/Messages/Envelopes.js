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
    e.preventDefault();
    this.props.showOverlay(envelope);
    this.props.handleSelect(id);
    this.setState({...this.state, selected:id});
  }

  handleCheck = (id, checked) => {
    this.props.handleCheck(id, checked);
  }

  handleRightSwipe = (id) => {
    console.log("Right swipe detected");
    console.log(id);
  }

  handleLeftSwipe = (id) => {
    console.log("Left swipe detected");
    console.log(id);
  }

  render() {
    const message_list = this.props.message_ids.map(id => {
      if (id.toString() in this.state.envelopes) {
        return (
          <Envelope
            handleClick={this.handleClick}
            handleCheck={this.handleCheck}
            handleLeftSwipe={this.handleLeftSwipe}
            handleRightSwipe={this.handleRightSwipe}
            envelope={this.state.envelopes[id]}
            checked={}
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
