/**
 * Fetches message ids for current users/folder and displays them
 */

import React, { useState, useCallback, useEffect, useRef } from 'react';
import Envelopes from './Envelopes';
import Folders from './Folders';
import Actions from '../Actions';
import useApi from '../../hooks/useApi';
import { READ, UNREAD, ASC, DESC, ARRIVAL, DATE, FROM, SUBJECT } from '../../constants';
import './Messages.css';

function Messages({ token, api_url, folder, host, showOverlay, setFolder: setFolderProp, setMessage }) {
  const api = useApi();

  const [messageIds, setMessageIds] = useState([]);
  const [selectedMessages, setSelectedMessages] = useState([]);
  const [sortOrder, setSortOrder] = useState(DESC);
  const [sortField, setSortField] = useState(DATE);
  const [loading, setLoading] = useState(true);

  const callbackTimeoutRef = useRef(null);
  const archiveTimeoutRef = useRef(null);
  const intervalRef = useRef(null);

  // Polling effect — runs on mount and whenever folder/sort changes
  useEffect(() => {
    let cancelled = false;

    function poll() {
      api.getMessages(folder, sortOrder.imap, sortField.imap)
        .then(data => {
          if (!cancelled) {
            setMessageIds(data.data.message_ids);
            setLoading(false);
          }
        })
        .catch(e => {
          if (!cancelled) {
            setMessage("Unable to get list of messages.", true);
            console.log(e);
          }
        });
    }

    setLoading(true);
    poll();

    intervalRef.current = setInterval(poll, 10000);

    return () => {
      cancelled = true;
      clearInterval(intervalRef.current);
    };
  }, [api, folder, sortOrder, sortField, setMessage]);

  // Cleanup non-polling timers on unmount
  useEffect(() => {
    return () => {
      clearTimeout(callbackTimeoutRef.current);
      clearTimeout(archiveTimeoutRef.current);
    };
  }, []);

  const callback = useCallback((data) => {
    setMessageIds([]);
    setLoading(true);
    callbackTimeoutRef.current = setTimeout(() => {
      setMessageIds(data.data.message_ids);
      setLoading(false);
    }, 1);
  }, []);

  const catchback = useCallback((err) => {
    setMessage("Unable to set flag on selected messages.", true);
    console.log("Unable to set flag on selected messages.");
    console.error(err);
  }, [setMessage]);

  const handleCheck = useCallback((message_id, checked) => {
    const id = parseInt(message_id);
    setSelectedMessages(prev =>
      checked ? [...prev, id] : prev.filter(i => id !== i)
    );
  }, []);

  const handleSelect = useCallback((message_id) => {
    // kept for API compatibility — not currently rendered
    parseInt(message_id);
  }, []);

  const archive = useCallback((message_id) => {
    api.setFlag(
      folder,
      READ.imap,
      READ.op,
      [message_id],
      sortOrder.imap,
      sortField.imap
    ).then(() => {
      archiveTimeoutRef.current = setTimeout(() => {
        api.moveMessages(
          folder,
          'Archive',
          [message_id],
          sortOrder.imap,
          sortField.imap
        );
      }, 500);
    });
  }, [api, folder, sortOrder, sortField]);

  const markRead = useCallback((message_id) => {
    return api.setFlag(
      folder,
      READ.imap,
      READ.op,
      [message_id],
      sortOrder.imap,
      sortField.imap
    );
  }, [api, folder, sortOrder, sortField]);

  const markUnread = useCallback((message_id) => {
    return api.setFlag(
      folder,
      UNREAD.imap,
      UNREAD.op,
      [message_id],
      sortOrder.imap,
      sortField.imap
    );
  }, [api, folder, sortOrder, sortField]);

  const sortAscending = useCallback((e) => {
    e.preventDefault();
    setSortOrder(ASC);
    setLoading(true);
  }, []);

  const sortDescending = useCallback((e) => {
    e.preventDefault();
    setSortOrder(DESC);
    setLoading(true);
  }, []);

  const handleSortField = useCallback((e) => {
    e.preventDefault();
    const fields = { [SUBJECT.imap]: SUBJECT, [DATE.imap]: DATE, [ARRIVAL.imap]: ARRIVAL, [FROM.imap]: FROM };
    const field = fields[e.target.value] || DATE;
    setSortField(field);
    setLoading(true);
  }, []);

  const handleSetFolder = useCallback((f) => {
    setSelectedMessages([]);
    setFolderProp(f);
  }, [setFolderProp]);

  const options = [DATE, ARRIVAL, SUBJECT, FROM].map(i => {
    return <option id={i.css} value={i.imap} key={i.imap}>{i.description}</option>;
  });
  const selected = selectedMessages.length ? " selected" : " none_selected";

  if (loading) {
    return <div className="email_list loading">Loading...</div>;
  }

  return (
    <div className="email_list">
      <div className="sticky">
        <div className={`filters filters-dropdowns ${sortOrder.css}`}>
          <Folders
            token={token}
            api_url={api_url}
            setFolder={handleSetFolder}
            host={host}
            folder={folder}
            setMessage={setMessage}
            label="Folder"
          />&nbsp;
          <div>
            <span className="filter filter-sort">
              <label htmlFor="sort-field">Sort by:</label>
              <select id="sort-by" name="sort-by" className="sort-by" onChange={handleSortField}>
                {options}
              </select>
              <button
                id={ASC.css}
                className="sort-order"
                title="Sort ascending"
                onClick={sortAscending}
              >&nbsp;
                <hr className="long first" />
                <hr className="medium second" />
                <hr className="short third" />
              </button>
              <button
                id={DESC.css}
                className="sort-order"
                title="Sort descending"
                onClick={sortDescending}
              >&nbsp;
                <hr className="short first" />
                <hr className="medium second" />
                <hr className="long third" />
              </button>
            </span>
          </div>
        </div>
        <Actions
          token={token}
          api_url={api_url}
          host={host}
          folder={folder}
          selected_messages={selectedMessages}
          selected={selected}
          order={sortOrder.imap}
          field={sortField.imap}
          callback={callback}
          catchback={catchback}
          setMessage={setMessage}
        />
      </div>
      <Envelopes
        message_ids={messageIds}
        folder={folder}
        host={host}
        token={token}
        api_url={api_url}
        selected_messages={selectedMessages}
        showOverlay={showOverlay}
        handleCheck={handleCheck}
        handleSelect={handleSelect}
        setMessage={setMessage}
        markUnread={markUnread}
        markRead={markRead}
        archive={archive}
      />
    </div>
  );
}

export default Messages;
