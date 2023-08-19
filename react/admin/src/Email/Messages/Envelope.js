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
      archived: -1,
      checked: false
    };
  }

  handleClick = (e) => {
    e.preventDefault();
    this.props.handleClick(this.props.envelope, this.props.dom_id);
  }

  handleCheckChange = (e) => {
    this.setState({ ...this.state, checked: e.target.checked });
  }

  handleCheck = () => {
    console.log(`Checkbox clicked. Handler in Envelope class invoked. Current state: ${this.props.is_checked}`);
    this.props.handleCheck(this.props.dom_id, !this.props.is_checked, this.props.page);
  }

  archive = () => {
    this.setState({...this.state, archived: this.props.dom_id});
    this.props.archive(this.props.dom_id);
  }

  markUnread = () => {
    this.props.markUnread(this.props.dom_id, this.props.page);
  }

  markRead = () => {
    this.props.markRead(this.props.dom_id, this.props.page);
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
    const archived = this.state.archived === this.props.dom_id ? "archived" : "";
    const attachment = (message.struct[1] === "mixed" ? "Attachment" : "");
    const priority = message.priority !== "" ? ` ${message.priority}` : "";
    const selected = this.props.selected ? "selected" : "";
    const classes = [flags, attachment, priority, selected, archived].join(" ");
    return (
      <SwipeableListItem
        threshold={0.5}
        className={`message-row ${classes}`}
        key={this.props.dom_id}
        leadingActions={leadingActions()}
        trailingActions={trailingActions()}
      >
        <div className="message-line-1" id={this.props.dom_id ? this.props.dom_id : "s"}>
          <div className="message-field message-from" title={message.from[0]}>{message.from[0]}</div>
          <div className="message-field message-date">{message.date}</div>
        </div>
        <div className="message-field message-subject">
        <input
            type="checkbox"
            name={this.props.dom_id}
            id={this.props.dom_id}
            onChange={this.handleCheckChange}
            checked={this.props.is_checked}
          />
          <label htmlFor={this.props.dom_id} onClick={this.handleCheck}>
            <span className="checked">✓</span><span className="unchecked">&nbsp;</span>
          </label>&nbsp;
          {(priority !== " ") && (priority !== "") ? '❗️ ' : ''}
          {flags.match(/Flagged/) ? '🚩 ' : ''}
          {flags.match(/Answered/) ? '⤶ ' : ''}
          {message.struct[1] === "mixed" ? '📎 ' : ''}
          <span className="subject" id={this.props.dom_id} onClick={this.handleClick}>{message.subject}</span>
        </div>
      </SwipeableListItem>
    );
  }
}

export default Envelope;
