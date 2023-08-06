import React from 'react';
import ApiClient from '../../ApiClient';
import './Envelopes.css';
import {
  LeadingActions,
  SwipeableListItem,
  SwipeAction,
  TrailingActions,
} from 'react-swipeable-list';
import 'react-swipeable-list/dist/styles.css';

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

  handleRightSwipe = (e) => {
    console.log("Right swipe detected");
    console.log(e);
  }

  render() {
    const message_list = this.props.message_ids.map(id => {
      if (id.toString() in this.state.envelopes) {
        const leadingActions = () => (
          <LeadingActions>
            <SwipeAction data-id={id} onClick={this.handleLeftSwipe}>Mark as read</SwipeAction>
          </LeadingActions>
        );
        const trailingActions = () => (
          <TrailingActions>
            <SwipeAction data-id={id} onClick={this.handleRightSwipe}>Archive</SwipeAction>
          </TrailingActions>
        );
        var message = this.state.envelopes[id];
        var flags = message.flags.map(d => {return d.replace("\\","")}).join(" ");
        var attachment = (message.struct[1] === "mixed" ? " Attachment" : "");
        var priority = message.priority !== "" ? ` ${message.priority}` : "";
        var selected = this.state.selected === id.toString() ? " selected" : "";
        var classes = flags + attachment + priority + selected;
        return (
          <SwipeableListItem className={`message-row ${classes}`} key={id} leadingActions={leadingActions()}>
            <div className="message-line-1">
              <div className="message-field message-from" title={message.from[0]}>{message.from[0]}</div>
              <div className="message-field message-date">{message.date}</div>
            </div>
            <div className="message-field message-subject">
              <input
                type="checkbox"
                id={id}
                checked={this.props.selected_messages.includes(id)}
                onChange={this.handleCheck}
              />
              <label htmlFor={id}><span className="checked">✓</span><span className="unchecked">&nbsp;</span></label>&nbsp;
              {(priority !== " ") && (priority !== "") ? '❗️ ' : ''}
              {flags.match(/Flagged/) ? '🚩 ' : ''}
              {flags.match(/Answered/) ? '⤶ ' : ''}
              {message.struct[1] === "mixed" ? '📎 ' : ''}
              <span className="subject" id={id} onClick={this.handleClick}>{message.subject}</span>
            </div>
          </SwipeableListItem>
        );
      }
      return (
        <li className="message-row loading" key={id}>
          <div className="message-line-1">
            <div className="message-field message-from">&nbsp;</div>
            <div className="message-field message-date">&nbsp;</div>
          </div>
          <div className="message-field message-subject">&nbsp;</div>
        </li>
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
