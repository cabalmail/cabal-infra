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

  handleClick = (e) => {
    e.preventDefault();
    this.props.handleClick(this.props.envelope, this.props.id);
  }

  handleCheck = () => {
    console.log(`ID: ${this.props.id}; Checked: ${this.props.checked}`);
    this.props.handleCheck(this.props.id, this.props.checked);
  }

  handleRightSwipe = () => {
    console.log("Right swipe detected");
    this.props.handleRightSwipe(this.props.id)
  }

  handleLeftSwipe = () => {
    console.log("Left swipe detected");
    this.props.handleLeftSwipe(this.props.id)
  }

  render() {
    const leadingActions = () => {
      return (
        <LeadingActions>
          <SwipeAction onClick={this.handleLeftSwipe}>Toggle read</SwipeAction>
        </LeadingActions>
      );
    };
    const trailingActions = () => {
      return (
        <TrailingActions>
          <SwipeAction onClick={this.handleRightSwipe}>Archive</SwipeAction>
        </TrailingActions>
      );
    };
    const message = this.props.envelope;
    const flags = message.flags.map(d => {return d.replace("\\","")}).join(" ");
    const attachment = (message.struct[1] === "mixed" ? " Attachment" : "");
    const priority = message.priority !== "" ? ` ${message.priority}` : "";
    const selected = this.props.selected ? " selected" : "";
    const classes = flags + attachment + priority + selected;
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
