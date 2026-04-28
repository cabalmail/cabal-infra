/**
 * Middle pane — message list. Per §4c of the redesign handoff:
 *   header (folder title + N of M + filter pills + sort strip),
 *   bulk-mode toolbar replacement,
 *   empty state,
 *   and the list of Envelopes below.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ArrowLeft, PenSquare } from 'lucide-react';
import Envelopes from './Envelopes';
import FolderPicker from './Folders';
import Icon from './icons';
import useApi from '../../hooks/useApi';
import { READ, UNREAD, FLAGGED, ASC, DESC, ARRIVAL, DATE, FROM, SUBJECT } from '../../constants';
import './Messages.css';

const SORT_OPTIONS = [DATE, ARRIVAL, FROM, SUBJECT];

function Messages({
  folder,
  host,
  showOverlay,
  setFolder: setFolderProp,
  setMessage,
  addressFilter,
  filter,
  setFilter,
  sortKey,
  setSortKey,
  sortDir,
  setSortDir,
  bulkMode,
  setBulkMode,
  selected,
  setSelected,
  layout = 'desktop',
  onOpenDrawer,
  onCompose,
}) {
  const api = useApi();

  const [messageIds, setMessageIds] = useState([]);
  const [loading, setLoading] = useState(true);
  const [visible, setVisible] = useState({ loaded: [], totalIds: 0, shownIds: [] });
  const [showMovePicker, setShowMovePicker] = useState(false);

  const intervalRef = useRef(null);
  const lastSelectedRef = useRef(null);

  // Polling: fetch message IDs on mount and whenever folder/sort changes.
  useEffect(() => {
    let cancelled = false;

    function poll() {
      api
        .getMessages(folder, sortDir.imap, sortKey.imap)
        .then((data) => {
          if (cancelled) return;
          setMessageIds(data.data.message_ids);
          setLoading(false);
        })
        .catch((e) => {
          if (cancelled) return;
          setMessage('Unable to get list of messages.', true);
          console.log(e);
        });
    }

    setLoading(true);
    poll();
    intervalRef.current = setInterval(poll, 10000);

    return () => {
      cancelled = true;
      clearInterval(intervalRef.current);
    };
  }, [api, folder, sortDir, sortKey, setMessage]);

  // Selection gets cleared when folder or filter changes.
  useEffect(() => {
    setSelected(new Set());
    lastSelectedRef.current = null;
  }, [folder, addressFilter, setSelected]);

  // Counts from the loaded envelopes. These undercount until all pages load,
  // matching the prototype where the full set lives in memory.
  const counts = useMemo(() => {
    const loaded = visible.loaded || [];
    let unread = 0;
    let flagged = 0;
    for (const e of loaded) {
      if (!e.flags.includes('\\Seen')) unread++;
      if (e.flags.includes('\\Flagged')) flagged++;
    }
    return { all: loaded.length, unread, flagged };
  }, [visible.loaded]);

  const selectedIdsArray = useMemo(() => Array.from(selected), [selected]);
  const selectedCount = selected.size;

  const exitBulk = useCallback(() => {
    setBulkMode(false);
    setSelected(new Set());
    setShowMovePicker(false);
    lastSelectedRef.current = null;
  }, [setBulkMode, setSelected]);

  const toggleBulk = useCallback(() => {
    if (bulkMode) exitBulk();
    else setBulkMode(true);
  }, [bulkMode, exitBulk, setBulkMode]);

  const refreshAfterMutation = useCallback(() => {
    setLoading(true);
    api
      .getMessages(folder, sortDir.imap, sortKey.imap)
      .then((data) => {
        setMessageIds(data.data.message_ids);
        setLoading(false);
      })
      .catch((e) => {
        console.log(e);
        setLoading(false);
      });
  }, [api, folder, sortDir, sortKey]);

  const runFlagOp = useCallback(
    (spec, ids) => {
      if (!ids.length) return;
      api
        .setFlag(folder, spec.imap, spec.op, ids, sortDir.imap, sortKey.imap)
        .then(refreshAfterMutation)
        .catch((err) => {
          setMessage('Unable to set flag on selected messages.', true);
          console.error(err);
        });
    },
    [api, folder, sortDir, sortKey, refreshAfterMutation, setMessage],
  );

  const archiveSelected = useCallback(() => {
    if (!selectedCount) return;
    api
      .moveMessages(folder, 'Archive', selectedIdsArray, sortDir.imap, sortKey.imap)
      .then(() => {
        refreshAfterMutation();
        exitBulk();
      })
      .catch((err) => {
        setMessage('Unable to archive selected messages.', true);
        console.error(err);
      });
  }, [api, folder, sortDir, sortKey, selectedIdsArray, selectedCount, refreshAfterMutation, exitBulk, setMessage]);

  const deleteSelected = useCallback(() => {
    if (!selectedCount) return;
    api
      .moveMessages(folder, 'Deleted Messages', selectedIdsArray, sortDir.imap, sortKey.imap)
      .then(() => {
        refreshAfterMutation();
        exitBulk();
      })
      .catch((err) => {
        setMessage('Unable to delete selected messages.', true);
        console.error(err);
      });
  }, [api, folder, sortDir, sortKey, selectedIdsArray, selectedCount, refreshAfterMutation, exitBulk, setMessage]);

  const moveSelected = useCallback(
    (destination) => {
      setShowMovePicker(false);
      if (!selectedCount || !destination || destination === folder) return;
      api
        .moveMessages(folder, destination, selectedIdsArray, sortDir.imap, sortKey.imap)
        .then(() => {
          refreshAfterMutation();
          exitBulk();
        })
        .catch((err) => {
          setMessage('Unable to move selected messages.', true);
          console.error(err);
        });
    },
    [api, folder, sortDir, sortKey, selectedIdsArray, selectedCount, refreshAfterMutation, exitBulk, setMessage],
  );

  const markReadSelected = useCallback(() => runFlagOp(READ, selectedIdsArray), [runFlagOp, selectedIdsArray]);
  const markUnreadSelected = useCallback(() => runFlagOp(UNREAD, selectedIdsArray), [runFlagOp, selectedIdsArray]);
  const flagSelected = useCallback(() => runFlagOp(FLAGGED, selectedIdsArray), [runFlagOp, selectedIdsArray]);

  // Single-row ops (swipe actions on one envelope).
  const markReadOne = useCallback(
    (id) =>
      api
        .setFlag(folder, READ.imap, READ.op, [id], sortDir.imap, sortKey.imap)
        .catch((e) => console.error(e)),
    [api, folder, sortDir, sortKey],
  );
  const markUnreadOne = useCallback(
    (id) =>
      api
        .setFlag(folder, UNREAD.imap, UNREAD.op, [id], sortDir.imap, sortKey.imap)
        .catch((e) => console.error(e)),
    [api, folder, sortDir, sortKey],
  );
  const archiveOne = useCallback(
    (id) => {
      api
        .setFlag(folder, READ.imap, READ.op, [id], sortDir.imap, sortKey.imap)
        .then(() =>
          api.moveMessages(folder, 'Archive', [id], sortDir.imap, sortKey.imap),
        )
        .then(refreshAfterMutation)
        .catch((e) => console.error(e));
    },
    [api, folder, sortDir, sortKey, refreshAfterMutation],
  );

  const handleFolderChange = useCallback(
    (nextFolder) => {
      exitBulk();
      setFolderProp(nextFolder);
    },
    [exitBulk, setFolderProp],
  );

  const handleSortKeyChange = useCallback(
    (e) => {
      const next = SORT_OPTIONS.find((o) => o.imap === e.target.value) || DATE;
      setSortKey(next);
    },
    [setSortKey],
  );

  const toggleSortDir = useCallback(() => {
    setSortDir(sortDir.css === 'descending' ? ASC : DESC);
  }, [sortDir, setSortDir]);

  const handleVisibleChange = useCallback((info) => {
    setVisible(info);
  }, []);

  const title = addressFilter || folder;
  const totalShown = visible.shownIds ? visible.shownIds.length : 0;
  const totalIds = visible.totalIds || messageIds.length;

  // --- Header -------------------------------------------------------------
  const renderHeader = () => {
    if (bulkMode) {
      return (
        <div className="msglist-header bulk" role="toolbar" aria-label="Bulk message actions">
          <div className="msglist-bulk-count">
            <span className="msglist-bulk-num">{selectedCount}</span>
            <span className="msglist-bulk-label">selected</span>
          </div>
          <div className="msglist-bulk-actions">
            <button type="button" className="tool-btn" onClick={archiveSelected} disabled={!selectedCount}>
              <Icon name="archive" size={14} />
              <span className="tool-btn-label">Archive</span>
            </button>
            <div className="tool-btn-group">
              <button
                type="button"
                className="tool-btn"
                onClick={() => setShowMovePicker((v) => !v)}
                disabled={!selectedCount}
                aria-haspopup="true"
                aria-expanded={showMovePicker}
              >
                <Icon name="move" size={14} />
                <span className="tool-btn-label">Move</span>
                <Icon name="chevron-down" size={12} />
              </button>
              {showMovePicker && (
                <div className="msglist-move-picker">
                  <FolderPicker
                    folder={folder}
                    setFolder={moveSelected}
                    setMessage={setMessage}
                    label="Move to"
                  />
                </div>
              )}
            </div>
            <button type="button" className="tool-btn" onClick={markReadSelected} disabled={!selectedCount}>
              <Icon name="mark-read" size={14} />
              <span className="tool-btn-label">Mark read</span>
            </button>
            <button type="button" className="tool-btn" onClick={markUnreadSelected} disabled={!selectedCount}>
              <Icon name="mark-unread" size={14} />
              <span className="tool-btn-label">Mark unread</span>
            </button>
            <button type="button" className="tool-btn" onClick={flagSelected} disabled={!selectedCount}>
              <Icon name="flag" size={14} />
              <span className="tool-btn-label">Flag</span>
            </button>
            <button type="button" className="tool-btn danger" onClick={deleteSelected} disabled={!selectedCount}>
              <Icon name="trash" size={14} />
              <span className="tool-btn-label">Delete</span>
            </button>
          </div>
          <button
            type="button"
            className="msglist-bulk-exit"
            onClick={exitBulk}
            title="Exit bulk selection"
            aria-label="Exit bulk selection"
          >
            <Icon name="close" size={13} />
          </button>
        </div>
      );
    }

    return (
      <div className="msglist-header">
        <div className="msglist-title-row">
          {layout !== 'desktop' && (
            <button
              type="button"
              className="msglist-phone-btn msglist-phone-back"
              onClick={() => typeof onOpenDrawer === 'function' && onOpenDrawer()}
              aria-label="Open navigation"
            >
              <ArrowLeft size={18} aria-hidden="true" />
            </button>
          )}
          <h1 className="msglist-title" title={title}>{title}</h1>
          <span className="msglist-meta">
            {totalIds > 0 ? `${totalShown} of ${totalIds}` : '0'}
          </span>
          {layout === 'phone' && (
            <button
              type="button"
              className="msglist-phone-btn msglist-phone-compose"
              onClick={() => typeof onCompose === 'function' && onCompose()}
              aria-label="New message"
            >
              <PenSquare size={18} aria-hidden="true" />
            </button>
          )}
        </div>
        <div className="msglist-tabs" role="tablist" aria-label="Message filter">
          {['all', 'unread', 'flagged'].map((f) => (
            <button
              key={f}
              type="button"
              role="tab"
              aria-selected={filter === f}
              className={`msglist-tab ${filter === f ? 'active' : ''}`}
              onClick={() => setFilter(f)}
            >
              <span className="msglist-tab-label">{f[0].toUpperCase() + f.slice(1)}</span>
              <span className="msglist-tab-count">{counts[f]}</span>
            </button>
          ))}
        </div>
        <div className="msglist-sort">
          <label className="msglist-sort-label">
            <span>Sort</span>
            <span className="msglist-sort-sep">·</span>
            <select
              value={sortKey.imap}
              onChange={handleSortKeyChange}
              className="msglist-sort-select"
              aria-label="Sort by"
            >
              {SORT_OPTIONS.map((o) => (
                <option key={o.imap} value={o.imap}>
                  {o.description}
                </option>
              ))}
            </select>
            <button
              type="button"
              className={`msglist-sort-dir ${sortDir.css}`}
              onClick={toggleSortDir}
              aria-label={`Sort ${sortDir.css === 'descending' ? 'descending' : 'ascending'}`}
              title={sortDir.css === 'descending' ? 'Descending' : 'Ascending'}
            >
              <Icon name="chevron-down" size={12} />
            </button>
          </label>
          <button
            type="button"
            className={`msglist-select-toggle ${bulkMode ? 'on' : ''}`}
            onClick={toggleBulk}
            title={bulkMode ? 'Exit select mode' : 'Select multiple'}
          >
            <Icon name="check" size={13} />
            <span>Select</span>
          </button>
        </div>
      </div>
    );
  };

  const emptyLabel = (() => {
    if (filter === 'unread') return 'No unread messages.';
    if (filter === 'flagged') return 'No flagged messages.';
    if (addressFilter) return `No messages for ${addressFilter}.`;
    return 'Inbox zero.';
  })();

  return (
    <div className={`msglist ${bulkMode ? 'select-mode' : ''}`} data-host={host || undefined}>
      <div className="msglist-sticky">{renderHeader()}</div>
      {loading && messageIds.length === 0 ? (
        <div className="msglist-loading" role="status" aria-label="Loading messages">
          <ul className="msglist-skel" aria-hidden="true">
            {[0, 1, 2, 3].map((i) => (
              <li key={i} className="msglist-skel-row">
                <span className="msglist-skel-dot" />
                <span className="msglist-skel-lines">
                  <span className="msglist-skel-line msglist-skel-line-from" />
                  <span className="msglist-skel-line msglist-skel-line-subject" />
                </span>
                <span className="msglist-skel-date" />
              </li>
            ))}
          </ul>
          <span className="sr-only">Loading messages…</span>
        </div>
      ) : (
        <Envelopes
          message_ids={messageIds}
          folder={folder}
          showOverlay={showOverlay}
          selected={selected}
          setSelected={setSelected}
          lastSelectedRef={lastSelectedRef}
          bulkMode={bulkMode}
          setBulkMode={setBulkMode}
          filter={filter}
          addressFilter={addressFilter}
          emptyLabel={emptyLabel}
          onVisibleEnvelopesChange={handleVisibleChange}
          markUnread={markUnreadOne}
          markRead={markReadOne}
          archive={archiveOne}
        />
      )}
    </div>
  );
}

export default Messages;
