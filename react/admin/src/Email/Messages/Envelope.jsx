import React, { useCallback, useMemo } from 'react';
import {
  LeadingActions,
  SwipeableListItem,
  SwipeAction,
  TrailingActions,
} from 'react-swipeable-list';
import 'react-swipeable-list/dist/styles.css';
import Icon from './icons';
import formatDate, { extractName } from '../../utils/formatDate';

function Envelope({
  handleClick: handleClickProp,
  toggleSelect,
  archive: archiveProp,
  markRead: markReadProp,
  markUnread: markUnreadProp,
  envelope,
  subject,
  priority,
  date,
  from,
  flags,
  struct,
  is_checked,
  dom_id,
  bulkMode,
  selected,
  observer,
}) {
  const flagStr = useMemo(() => flags.map((f) => f.replace('\\', '')).join(' '), [flags]);
  const unread = !flagStr.match(/Seen/);
  const flagged = !!flagStr.match(/Flagged/);
  const answered = !!flagStr.match(/Answered/);
  const hasAttachment = struct && struct[1] === 'mixed';
  const isImportant = Array.isArray(priority)
    && priority.some((p) => p === 'priority-1' || p === 'priority-2');
  const fromName = extractName(from && from[0]) || (from && from[0]) || '';
  const relDate = formatDate(date);

  const handleRowClick = useCallback(
    (e) => {
      if (bulkMode || e.shiftKey || e.metaKey || e.ctrlKey) {
        e.preventDefault();
        toggleSelect(dom_id, { shift: e.shiftKey, meta: e.metaKey || e.ctrlKey });
        return;
      }
      handleClickProp(envelope, dom_id);
    },
    [bulkMode, toggleSelect, dom_id, handleClickProp, envelope],
  );

  const handleLeadingClick = useCallback(
    (e) => {
      e.stopPropagation();
      toggleSelect(dom_id, { shift: e.shiftKey, meta: e.metaKey || e.ctrlKey });
    },
    [toggleSelect, dom_id],
  );

  const archive = useCallback(() => archiveProp(dom_id), [archiveProp, dom_id]);
  const markUnread = useCallback(() => markUnreadProp(dom_id), [markUnreadProp, dom_id]);
  const markRead = useCallback(() => markReadProp(dom_id), [markReadProp, dom_id]);

  const leadingActions = () => (
    <LeadingActions>
      <SwipeAction onClick={unread ? markRead : markUnread}>
        {unread ? 'Mark read' : 'Mark unread'}
      </SwipeAction>
    </LeadingActions>
  );

  const trailingActions = () => (
    <TrailingActions>
      <SwipeAction onClick={archive}>Archive</SwipeAction>
    </TrailingActions>
  );

  const rowClasses = [
    'envelope-row',
    unread ? 'unread' : 'read',
    flagged ? 'flagged' : '',
    isImportant ? 'important' : '',
    selected ? 'selected' : '',
    is_checked ? 'checked' : '',
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <SwipeableListItem
      threshold={0.5}
      className={rowClasses}
      key={dom_id}
      leadingActions={leadingActions()}
      trailingActions={trailingActions()}
    >
      {observer}
      <div
        className="envelope-content"
        role="button"
        tabIndex={0}
        onClick={handleRowClick}
        data-id={dom_id}
      >
        <span
          className={`envelope-leading ${bulkMode ? 'as-checkbox' : ''}`}
          onClick={handleLeadingClick}
          title={bulkMode ? 'Select message' : unread ? 'Unread' : 'Read'}
        >
          <span className="envelope-dot" aria-hidden="true" />
          <span
            className={`envelope-checkbox ${is_checked ? 'checked' : ''}`}
            role="checkbox"
            aria-checked={is_checked}
            aria-label={is_checked ? 'Deselect' : 'Select'}
          >
            {is_checked && <Icon name="check" size={10} />}
          </span>
        </span>
        <div className="envelope-main">
          <div className="envelope-head">
            <span className="envelope-from" title={from && from[0]}>
              {fromName}
            </span>
            <span className="envelope-date">{relDate}</span>
          </div>
          <div className="envelope-subject" title={subject}>
            {subject}
          </div>
        </div>
        <div className="envelope-indicators" aria-hidden="true">
          {isImportant && <Icon name="important" size={13} className="indicator-important" />}
          {hasAttachment && <Icon name="paperclip" size={13} />}
          {answered && <Icon name="reply" size={13} />}
          {flagged && <Icon name="star-fill" size={13} className="indicator-flagged" />}
        </div>
      </div>
    </SwipeableListItem>
  );
}

export default Envelope;
