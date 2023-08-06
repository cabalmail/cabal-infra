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

  handleClick = (e) => {
    e.preventDefault();
    this.props.showOverlay(this.state.envelopes[e.target.id]);
    this.props.handleSelect(e.target.id);
    this.setState({...this.state, selected:e.target.id});
  }

  handleCheck = (e) => {
    this.props.handleCheck(e.target.id, e.target.checked);
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
            folder={this.props.folder}
            host={this.props.host}
            token={this.props.token}
            api_url={this.props.api_url}
            selected_messages={this.props.selected_messages}
            showOverlay={this.props.showOverlay}
            handleCheck={this.props.handleCheck}
            handleSelect={this.props.handleSelect}
            handleLeftSwipe={this.props.handleLeftSwipe}
            handleRightSwipe={this.props.handleRightSwipe}
            setMessage={this.props.setMessage}
            envelope={this.state.envelops[id]}
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
