import React from 'react';
import './Envelopes.css';
import {
  LeadingActions,
  SwipeableListItem,
  SwipeAction,
  TrailingActions,
} from 'react-swipeable-list';
import 'react-swipeable-list/dist/styles.css';

class Envelope extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      archived: false
    };
    this.api = new ApiClient(this.props.api_url, this.props.token, this.props.host);
  }

  handleClick = (e) => {
    e.preventDefault();
    this.props.handleClick(this.props.envelope, this.props.id);
  }

  handleCheck = () => {
    this.props.handleCheck(this.props.id, !this.props.checked);
  }

  archive = () => {
    this.setState({...this.state, archived: true});
    this.props.archive(this.props.id);
  }

  markUnread = () => {
    this.props.markUnread(this.props.id);
  }

  markRead = () => {
    this.props.markRead(this.props.id);
  }

  render() {
    const message = this.props.envelope;
    const flags = message.flags.map(d => {return d.replace("\\","")}).join(" ");
    const leadingActions = () => {
      const text = flags.match(/Seen/) ? "Mark unread" : "Mark read";
      const handler = flags.match(/Seen/) ? this.markUnread : this.markRead;
      return (
        <LeadingActions>
          <SwipeAction onClick={handler}>{text}</SwipeAction>
        </LeadingActions>
      );
    };
    const trailingActions = () => {
      return (
        <TrailingActions>
          <SwipeAction onClick={this.archive}>Archive</SwipeAction>
        </TrailingActions>
      );
    };
    const archived = this.state.archived ? "archived" : "";
    const attachment = (message.struct[1] === "mixed" ? "Attachment" : "");
    const priority = message.priority !== "" ? ` ${message.priority}` : "";
    const selected = this.props.selected ? "selected" : "";
    const classes = [flags, attachment, priority, selected, archived].join(" ");
    return (
      <SwipeableListItem
        threshold={0.5}
        className={`message-row ${classes}`}
        key={this.props.id}
        leadingActions={leadingActions()}
        trailingActions={trailingActions()}
      >
        <div className="message-line-1">
          <div className="message-field message-from" title={message.from[0]}>{message.from[0]}</div>
          <div className="message-field message-date">{message.date}</div>
        </div>
        <div className="message-field message-subject">
          <input
            type="checkbox"
            id={this.props.id}
            checked={this.props.checked}
            onChange={this.handleCheck}
          />
          <label htmlFor={this.props.id}><span className="checked">✓</span><span className="unchecked">&nbsp;</span></label>&nbsp;
          {(priority !== " ") && (priority !== "") ? '❗️ ' : ''}
          {flags.match(/Flagged/) ? '🚩 ' : ''}
          {flags.match(/Answered/) ? '⤶ ' : ''}
          {message.struct[1] === "mixed" ? '📎 ' : ''}
          <span className="subject" id={this.props.id} onClick={this.handleClick}>{message.subject}</span>
        </div>
      </SwipeableListItem>
    );
  }
}

export default Envelope;
