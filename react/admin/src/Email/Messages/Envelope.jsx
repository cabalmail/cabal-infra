import React, { useState, useCallback } from 'react';
import './Envelopes.css';
import {
  LeadingActions,
  SwipeableListItem,
  SwipeAction,
  TrailingActions,
} from 'react-swipeable-list';
import 'react-swipeable-list/dist/styles.css';

function Envelope({
  handleClick: handleClickProp, handleCheck: handleCheckProp,
  archive: archiveProp, markRead: markReadProp, markUnread: markUnreadProp,
  envelope, subject, priority, date, from, flags, struct,
  is_checked, dom_id, page, selected, observer
}) {
  const [archived, setArchived] = useState(-1);

  const handleClick = useCallback((e) => {
    e.preventDefault();
    handleClickProp(envelope, dom_id);
  }, [handleClickProp, envelope, dom_id]);

  const handleCheckChange = useCallback(() => {
    handleCheckProp(dom_id, !is_checked);
  }, [handleCheckProp, dom_id, is_checked]);

  const archive = useCallback(() => {
    setArchived(dom_id);
    archiveProp(dom_id);
  }, [archiveProp, dom_id]);

  const markUnread = useCallback(() => {
    markUnreadProp(dom_id, page);
  }, [markUnreadProp, dom_id, page]);

  const markRead = useCallback(() => {
    markReadProp(dom_id, page);
  }, [markReadProp, dom_id, page]);

  const flags_c = flags.map(d => d.replace("\\", "")).join(" ");

  const leadingActions = () => {
    const text = flags_c.match(/Seen/) ? "Mark unread" : "Mark read";
    const handler = flags_c.match(/Seen/) ? markUnread : markRead;
    return (
      <LeadingActions>
        <SwipeAction onClick={handler}>{text}</SwipeAction>
      </LeadingActions>
    );
  };

  const trailingActions = () => {
    return (
      <TrailingActions>
        <SwipeAction onClick={archive}>Archive</SwipeAction>
      </TrailingActions>
    );
  };

  const archived_c = archived === dom_id ? "archived" : "";
  const attachment_c = (struct[1] === "mixed" ? "Attachment" : "");
  const priority_c = priority !== "" ? ` ${priority}` : "";
  const selected_c = selected ? "selected" : "";
  const classes = [flags_c, attachment_c, priority_c, selected_c, archived_c].join(" ");

  return (
    <SwipeableListItem
      threshold={0.5}
      className={`message-row ${classes}`}
      key={dom_id}
      leadingActions={leadingActions()}
      trailingActions={trailingActions()}
    >
      {observer}
      <div className="message-line-1" id={dom_id ? dom_id : "s"}>
        <div className="message-field message-from" title={from[0]}>{from[0]}</div>
        <div className="message-field message-date">{date}</div>
      </div>
      <div className="message-field message-subject">
        <input
          type="checkbox"
          name={dom_id}
          id={dom_id}
          onChange={handleCheckChange}
          checked={is_checked}
        />
        <label htmlFor={dom_id} onClick={handleCheckChange}>
          <span className="checked">✓</span><span className="unchecked">&nbsp;</span>
        </label>&nbsp;
        {(priority_c !== " ") && (priority !== "") ? '❗️ ' : ''}
        {flags_c.match(/Flagged/) ? '🚩 ' : ''}
        {flags_c.match(/Answered/) ? '⤶ ' : ''}
        {struct[1] === "mixed" ? '📎 ' : ''}
        <span className="subject" id={dom_id} onClick={handleClick}>{subject}</span>
      </div>
    </SwipeableListItem>
  );
}

export default Envelope;
