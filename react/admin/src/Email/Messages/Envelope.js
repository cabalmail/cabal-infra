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
    this.props.handleCheck(this.props.dom_id, !this.props.is_checked);
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
    const { flags, subject, date, struct, selected, priority, from, dom_id, is_checked } = this.props;
    const flags_c = flags.map(d => {return d.replace("\\","")}).join(" ");
    const leadingActions = () => {
      const text = flags_c.match(/Seen/) ? "Mark unread" : "Mark read";
      const handler = flags_c.match(/Seen/) ? this.markUnread : this.markRead;
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
    const archived = this.state.archived === dom_id ? "archived" : "";
    const attachment_c = (struct[1] === "mixed" ? "Attachment" : "");
    const priority_c = priority !== "" ? ` ${priority}` : "";
    const selected_c = selected ? "selected" : "";
    const classes = [flags_c, attachment_c, priority_c, selected_c, archived].join(" ");
    return (
      <SwipeableListItem
        threshold={0.5}
        className={`message-row ${classes}`}
        key={dom_id}
        leadingActions={leadingActions()}
        trailingActions={trailingActions()}
      >
        <div className="message-line-1" id={dom_id ? dom_id : "s"}>
          <div className="message-field message-from" title={from[0]}>{from[0]}</div>
          <div className="message-field message-date">{date}</div>
        </div>
        <div className="message-field message-subject">
        <input
            type="checkbox"
            name={dom_id}
            id={dom_id}
            onChange={this.handleCheckChange}
            checked={is_checked}
          />
          <label htmlFor={dom_id} onClick={this.handleCheck}>
            <span className="checked">✓</span><span className="unchecked">&nbsp;</span>
          </label>&nbsp;
          {(priority_c !== " ") && (priority !== "") ? '❗️ ' : ''}
          {flags_c.match(/Flagged/) ? '🚩 ' : ''}
          {flags_c.match(/Answered/) ? '⤶ ' : ''}
          {struct[1] === "mixed" ? '📎 ' : ''}
          <span className="subject" id={dom_id} onClick={this.handleClick}>{subject}</span>
        </div>
      </SwipeableListItem>
    );
  }
}

export default Envelope;
