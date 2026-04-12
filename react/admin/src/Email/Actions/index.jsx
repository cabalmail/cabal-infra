import React, { useState, useCallback } from 'react';
import useApi from '../../hooks/useApi';
import Folders from '../Messages/Folders';
import './Actions.css';
import { READ, UNREAD, FLAGGED, UNFLAGGED, REPLY, REPLYALL, FORWARD } from '../../constants';

function Actions({
  folder, selected_messages, selected_message, selected,
  order, field, callback, catchback,
  setMessage, reply, replyAll, forward
}) {
  const api = useApi();
  const [showFolders, setShowFolders] = useState(false);

  const setDestination = useCallback((destination) => {
    setShowFolders(false);
    api.moveMessages(folder, destination, selected_messages, order, field);
  }, [api, folder, selected_messages, order, field]);

  const handleActionButtonClick = useCallback((e) => {
    e.stopPropagation();
    if (!selected_messages.length && !selected_message) {
      setMessage("Please select at least one message first.", true);
      return;
    }
    let action = e.target.id;
    if (e.target.tagName !== 'BUTTON') {
      action = e.target.parentElement.id;
    }
    switch (action) {
      case "delete":
        api.moveMessages(folder, "Deleted Messages", selected_messages, order, field);
        break;
      case "move":
        setShowFolders(true);
        break;
      case "cancel":
        setShowFolders(false);
        break;
      case READ.css:
        api.setFlag(folder, READ.imap, READ.op, selected_messages, order, field)
          .then(callback).catch(catchback);
        break;
      case UNREAD.css:
        api.setFlag(folder, UNREAD.imap, UNREAD.op, selected_messages, order, field)
          .then(callback).catch(catchback);
        break;
      case FLAGGED.css:
        api.setFlag(folder, FLAGGED.imap, FLAGGED.op, selected_messages, order, field)
          .then(callback).catch(catchback);
        break;
      case UNFLAGGED.css:
        api.setFlag(folder, UNFLAGGED.imap, UNFLAGGED.op, selected_messages, order, field)
          .then(callback).catch(catchback);
        break;
      case REPLY.css:
        reply();
        break;
      case REPLYALL.css:
        replyAll();
        break;
      case FORWARD.css:
        forward();
        break;
      default:
        console.log(`"${action}" clicked`);
    }
  }, [api, folder, selected_messages, selected_message, order, field, callback, catchback, setMessage, reply, replyAll, forward]);

  const show = showFolders ? "show_folders" : "hide_folders";

  return (
    <div className={`filters filters-buttons ${selected} ${show}`}>
      <span className="filter filter-actions">
        <span className="nowrap">
          <Folders
            setFolder={setDestination}
            folder={folder}
            setMessage={setMessage}
            label="Destination"
          />&nbsp;
          <button
            value="cancel"
            id="cancel"
            name="cancel"
            className="action cancel"
            title="Cancel move"
            onClick={handleActionButtonClick}
          >❌<span className="wide-screen"> Cancel move</span></button>
          <button
            value="delete"
            id="delete"
            name="delete"
            className="action delete"
            title="Delete"
            onClick={handleActionButtonClick}
          >🗑️<span className="wide-screen"> Delete</span></button>
          <button
            value="move"
            id="move"
            name="move"
            className="action move"
            title="Move to..."
            onClick={handleActionButtonClick}
          >📨<span className="wide-screen"> Move to...</span></button>
          <button
            value={READ.css}
            id={READ.css}
            name={READ.css}
            className={`action ${READ.css}`}
            title={READ.description}
            onClick={handleActionButtonClick}
          >{READ.icon}<span className="wide-screen"> {READ.description}</span></button>
          <button
            value={UNREAD.css}
            id={UNREAD.css}
            name={UNREAD.css}
            className={`action ${UNREAD.css}`}
            title={UNREAD.description}
            onClick={handleActionButtonClick}
          >{UNREAD.icon}<span className="wide-screen"> {UNREAD.description}</span></button>
          <button
            value={FLAGGED.css}
            id={FLAGGED.css}
            name={FLAGGED.css}
            className={`action ${FLAGGED.css}`}
            title={FLAGGED.description}
            onClick={handleActionButtonClick}
          >{FLAGGED.icon}<span className="wide-screen"> {FLAGGED.description}</span></button>
          <button
            value={UNFLAGGED.css}
            id={UNFLAGGED.css}
            name={UNFLAGGED.css}
            className={`action ${UNFLAGGED.css}`}
            title={UNFLAGGED.description}
            onClick={handleActionButtonClick}
          >{UNFLAGGED.icon}<span className="wide-screen"> {UNFLAGGED.description}</span></button>
        </span>
        <span className="wrap_point"> </span>
        <span className="nowrap">
          <button
            value={REPLY.css}
            id={REPLY.css}
            name={REPLY.css}
            className={`action ${REPLY.css}`}
            title={REPLY.description}
            onClick={handleActionButtonClick}
          >{REPLY.icon}<span className="wide-screen"> {REPLY.description}</span></button>
          <button
            value={REPLYALL.css}
            id={REPLYALL.css}
            name={REPLYALL.css}
            className={`action ${REPLYALL.css}`}
            title={REPLYALL.description}
            onClick={handleActionButtonClick}
          >{REPLYALL.icon}<span className="wide-screen"> {REPLYALL.description}</span></button>
          <button
            value={FORWARD.css}
            id={FORWARD.css}
            name={FORWARD.css}
            className={`action ${FORWARD.css}`}
            title={FORWARD.description}
            onClick={handleActionButtonClick}
          >{FORWARD.icon}<span className="wide-screen"> {FORWARD.description}</span></button>
        </span>
      </span>
    </div>
  );
}

export default Actions;
