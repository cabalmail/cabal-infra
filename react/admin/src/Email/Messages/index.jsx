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
import ConfirmDialog from '../../ConfirmDialog';
import useApi from '../../hooks/useApi';
import { READ, UNREAD, FLAGGED, ASC, DESC, ARRIVAL, DATE, FROM, SUBJECT, MAX_BULK_IDS, BULK_CHUNK_SIZE } from '../../constants';
import { folderMeta } from '../../utils/folderMeta';
import './Messages.css';

const SORT_OPTIONS = [DATE, ARRIVAL, FROM, SUBJECT];

// Run `ids` through `doChunk` in BULK_CHUNK_SIZE-sized slices, one at a time,
// calling `onProgress(doneCount)` after each slice lands. Sequential (not
// parallel) so the server sees a steady stream rather than a burst, and so a
// failure tells us exactly how many ids got through: on the first chunk that
// throws, the rejection carries `.done` (the count that succeeded before it)
// and `.cause` (the underlying error) so the caller can roll back the rest.
async function runInChunks(ids, chunkSize, doChunk, onProgress) {
  let done = 0;
  for (let start = 0; start < ids.length; start += chunkSize) {
    const chunk = ids.slice(start, start + chunkSize);
    try {
      await doChunk(chunk);
    } catch (cause) {
      const err = new Error('bulk chunk failed');
      err.done = done;
      err.cause = cause;
      throw err;
    }
    done += chunk.length;
    if (typeof onProgress === 'function') onProgress(done);
  }
  return done;
}

function Messages({
  folder,
  host,
  showOverlay,
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
  const [total, setTotal] = useState(0);
  // Server-sourced folder counts (IMAP STATUS + SEARCH FLAGGED). null until the
  // first /folder_status response, so the pills render without a count rather
  // than a wrong one. unseen/flagged drive the Unread/Flagged pills.
  const [status, setStatus] = useState({ messages: null, unseen: null, flagged: null });
  const [loading, setLoading] = useState(true);
  const [visible, setVisible] = useState({ loaded: [], totalIds: 0, shownIds: [] });
  const [showMovePicker, setShowMovePicker] = useState(false);
  const [confirmPurge, setConfirmPurge] = useState(false);
  // Non-null while a bulk action is streaming chunks to the server. Drives the
  // "Verb N of M" affordance and disables the toolbar without changing its
  // footprint. { verb, done, total }.
  const [bulkProgress, setBulkProgress] = useState(null);
  // Optimistic flag flip handed down to Envelopes for bulk mark-read/flag. A
  // fresh object (new `seq`) each time so the child effect re-fires even when
  // the same op repeats; the failure path sends the inverse to roll back.
  const [flagPatch, setFlagPatch] = useState(null);
  const flagSeqRef = useRef(0);

  // In Trash, "Delete" means gone forever (purge + expunge) instead of
  // another move into Trash, and always goes through a confirmation.
  const isTrash = folderMeta(folder).kind === 'trash';

  const intervalRef = useRef(null);
  const lastSelectedRef = useRef(null);
  // The "did the folder change" baseline for the poll. Refs, not closure
  // variables, so refreshAfterMutation can advance them too -- otherwise the
  // poll right after a bulk move/delete would see MESSAGES dropped against a
  // stale baseline and fire a needless second UID-list pull.
  const lastUidNextRef = useRef(null);
  const lastMessagesRef = useRef(null);
  // True while a bulk op holds the list in an optimistic state. The poll skips
  // its work until the op settles and re-seeds the baseline, so a mid-op tick
  // can't see the dropped MESSAGES count and re-pull the rows we just removed.
  const bulkBusyRef = useRef(false);
  // Live mirrors of messageIds/total, read at the start of a bulk op to snapshot
  // for rollback without threading them through every handler's deps.
  const messageIdsRef = useRef([]);
  const totalRef = useRef(0);

  // Keep the rollback mirrors in step with the rendered state.
  useEffect(() => { messageIdsRef.current = messageIds; }, [messageIds]);
  useEffect(() => { totalRef.current = total; }, [total]);

  // Pull the fresh STATUS and re-seed the change baseline. Shared by the poll
  // and refreshAfterMutation so both keep the baseline in step.
  const applyStatus = useCallback((data) => {
    const s = data.data;
    setStatus({ messages: s.messages, unseen: s.unseen, flagged: s.flagged });
    lastUidNextRef.current = s.uid_next;
    lastMessagesRef.current = s.messages;
  }, []);

  // Load the sorted UID list once on mount / folder / sort change, then poll
  // /folder_status (O(1)) instead of /list_messages (O(folder)) every 10s. The
  // UID list is only re-pulled when the folder actually changed -- UIDNEXT
  // advanced (a message arrived) or MESSAGES dropped (an expunge) -- mirroring
  // the Apple client's idle() heuristic. Reading/flagging shifts the pill
  // counts but not those two, so steady state stays cheap; the pills still
  // refresh every poll from STATUS.
  useEffect(() => {
    let cancelled = false;

    function loadIds() {
      return api
        .getMessages(folder, sortDir.imap, sortKey.imap)
        .then((data) => {
          if (cancelled) return;
          setMessageIds(data.data.message_ids);
          setTotal(data.data.total ?? data.data.message_ids.length);
          setLoading(false);
        });
    }

    function poll() {
      // A bulk op owns the list optimistically; leave it alone until it settles.
      if (bulkBusyRef.current) return;
      api
        .getFolderStatus(folder)
        .then((data) => {
          if (cancelled) return;
          const s = data.data;
          const changed =
            (lastUidNextRef.current !== null && s.uid_next > lastUidNextRef.current) ||
            (lastMessagesRef.current !== null && s.messages < lastMessagesRef.current);
          applyStatus(data);
          if (changed) loadIds().catch((e) => console.log(e));
        })
        .catch((e) => {
          if (!cancelled) console.log(e);
        });
    }

    // Switching folders/sort: clear the previous folder's list and counts so
    // the skeleton and bare pills show through the round trip instead of the
    // old folder's numbers (which can linger for seconds on a large folder).
    setMessageIds([]);
    setTotal(0);
    setStatus({ messages: null, unseen: null, flagged: null });
    lastUidNextRef.current = null;
    lastMessagesRef.current = null;
    setLoading(true);
    loadIds().catch((e) => {
      if (cancelled) return;
      setMessage('Unable to get list of messages.', true);
      console.log(e);
    });
    poll();
    intervalRef.current = setInterval(poll, 10000);

    return () => {
      cancelled = true;
      clearInterval(intervalRef.current);
    };
  }, [api, folder, sortDir, sortKey, setMessage, applyStatus]);

  // Selection gets cleared when folder or filter changes.
  useEffect(() => {
    setSelected(new Set());
    lastSelectedRef.current = null;
  }, [folder, addressFilter, setSelected]);

  // True only while the current folder's first list/STATUS round trip is in
  // flight (the skeleton is showing). Also gates the pills so a folder switch
  // doesn't flash an "All 0" before the real total lands.
  const initialLoading = loading && messageIds.length === 0;

  // Filter-pill counts come from the server, not loaded envelopes: All is the
  // folder total from /list_messages; Unread/Flagged are STATUS UNSEEN and the
  // SEARCH FLAGGED count from /folder_status. A null count (before the first
  // reply) renders the pill without a number rather than a wrong/zero one.
  const pillCounts = {
    all: initialLoading ? null : total || messageIds.length,
    unread: status.unseen,
    flagged: status.flagged,
  };

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
        setTotal(data.data.total ?? data.data.message_ids.length);
        setLoading(false);
      })
      .catch((e) => {
        console.log(e);
        setLoading(false);
      });
    // A bulk move/flag shifts the pill counts; pull fresh STATUS so they don't
    // lag a poll cycle behind the list. applyStatus also re-seeds the poll's
    // change baseline so the next tick doesn't re-pull the list off the now
    // lower MESSAGES count.
    api
      .getFolderStatus(folder)
      .then(applyStatus)
      .catch((e) => console.log(e));
  }, [api, folder, sortDir, sortKey, applyStatus]);

  // Refuse a bulk action larger than the server's per-request cap up front,
  // with a clear message, rather than firing a request the API answers 413.
  const bulkLimitExceeded = useCallback((count) => {
    if (count > MAX_BULK_IDS) {
      setMessage(
        `Select at most ${MAX_BULK_IDS.toLocaleString()} messages for one bulk action.`,
        true,
      );
      return true;
    }
    return false;
  }, [setMessage]);

  // Hand an optimistic flag flip down to Envelopes (new object per call so the
  // child effect always re-fires).
  const pushFlagPatch = useCallback((ids, flag, op) => {
    flagSeqRef.current += 1;
    setFlagPatch({ seq: flagSeqRef.current, ids, flag, op });
  }, []);

  // Close out a bulk op: drop the progress affordance, optionally leave bulk
  // mode, then reconcile the pill counts off a fresh STATUS instead of
  // re-pulling the UID list. applyStatus re-seeds the poll baseline; only then
  // do we release the poll, so it can't re-pull off the optimistic count.
  const settleBulk = useCallback(
    (exit) => {
      setBulkProgress(null);
      if (exit) exitBulk();
      api
        .getFolderStatus(folder)
        .then(applyStatus)
        .catch((e) => console.log(e))
        .finally(() => {
          bulkBusyRef.current = false;
        });
    },
    [api, folder, applyStatus, exitBulk],
  );

  // Bulk move/archive/delete/purge: drop the affected rows from the list now,
  // stream the operation to the server in chunks (showing progress), then
  // reconcile via STATUS. On a chunk failure, restore the rows past the point
  // that landed and surface the error -- the rows that did move stay gone.
  const runOptimisticRemoval = useCallback(
    (ids, { verb, failMessage, doChunk }) => {
      const numIds = ids.map(Number);
      if (!numIds.length) return;
      const removeSet = new Set(numIds);
      const snapshotIds = messageIdsRef.current;
      const snapshotTotal = totalRef.current;

      bulkBusyRef.current = true;
      setBulkProgress({ verb, done: 0, total: numIds.length });
      setMessageIds((prev) => prev.filter((id) => !removeSet.has(Number(id))));
      setTotal((t) => Math.max(0, t - numIds.length));

      runInChunks(numIds, BULK_CHUNK_SIZE, doChunk, (done) =>
        setBulkProgress({ verb, done, total: numIds.length }),
      )
        .then(() => settleBulk(true))
        .catch((err) => {
          const landed = err.done || 0;
          const moved = new Set(numIds.slice(0, landed));
          setMessageIds(snapshotIds.filter((id) => !moved.has(Number(id))));
          setTotal(Math.max(0, snapshotTotal - landed));
          setMessage(failMessage, true);
          console.error(err.cause || err);
          settleBulk(true);
        });
    },
    [settleBulk, setMessage],
  );

  const runFlagOp = useCallback(
    (spec, ids, verb) => {
      if (!ids.length) return;
      if (bulkLimitExceeded(ids.length)) return;
      const numIds = ids.map(Number);

      bulkBusyRef.current = true;
      setBulkProgress({ verb, done: 0, total: numIds.length });
      pushFlagPatch(numIds, spec.imap, spec.op);

      runInChunks(
        numIds,
        BULK_CHUNK_SIZE,
        (chunk) => api.setFlag(folder, spec.imap, spec.op, chunk, sortDir.imap, sortKey.imap),
        (done) => setBulkProgress({ verb, done, total: numIds.length }),
      )
        .then(() => settleBulk(false))
        .catch((err) => {
          // Roll the flag back on the ids whose chunk never landed.
          const reverted = numIds.slice(err.done || 0);
          pushFlagPatch(reverted, spec.imap, spec.op === 'set' ? 'unset' : 'set');
          setMessage('Unable to set flag on selected messages.', true);
          console.error(err.cause || err);
          settleBulk(false);
        });
    },
    [api, folder, sortDir, sortKey, pushFlagPatch, settleBulk, setMessage, bulkLimitExceeded],
  );

  const archiveSelected = useCallback(() => {
    if (!selectedCount) return;
    if (bulkLimitExceeded(selectedCount)) return;
    runOptimisticRemoval(selectedIdsArray, {
      verb: 'Archiving',
      failMessage: 'Unable to archive selected messages.',
      doChunk: (chunk) => api.moveMessages(folder, 'Archive', chunk, sortDir.imap, sortKey.imap),
    });
  }, [api, folder, sortDir, sortKey, selectedIdsArray, selectedCount, runOptimisticRemoval, bulkLimitExceeded]);

  const deleteSelected = useCallback(() => {
    if (!selectedCount) return;
    if (bulkLimitExceeded(selectedCount)) return;
    if (isTrash) {
      setConfirmPurge(true);
      return;
    }
    runOptimisticRemoval(selectedIdsArray, {
      verb: 'Deleting',
      failMessage: 'Unable to delete selected messages.',
      doChunk: (chunk) => api.moveMessages(folder, 'Trash', chunk, sortDir.imap, sortKey.imap),
    });
  }, [api, folder, isTrash, sortDir, sortKey, selectedIdsArray, selectedCount, runOptimisticRemoval, bulkLimitExceeded]);

  const purgeSelected = useCallback(() => {
    setConfirmPurge(false);
    if (!selectedCount) return;
    if (bulkLimitExceeded(selectedCount)) return;
    runOptimisticRemoval(selectedIdsArray, {
      verb: 'Deleting',
      failMessage: 'Unable to permanently delete selected messages.',
      doChunk: (chunk) => api.purgeMessages(folder, chunk),
    });
  }, [api, folder, selectedIdsArray, selectedCount, runOptimisticRemoval, bulkLimitExceeded]);

  const cancelPurge = useCallback(() => setConfirmPurge(false), []);

  const moveSelected = useCallback(
    (destination) => {
      setShowMovePicker(false);
      if (!selectedCount || !destination || destination === folder) return;
      if (bulkLimitExceeded(selectedCount)) return;
      runOptimisticRemoval(selectedIdsArray, {
        verb: 'Moving',
        failMessage: 'Unable to move selected messages.',
        doChunk: (chunk) => api.moveMessages(folder, destination, chunk, sortDir.imap, sortKey.imap),
      });
    },
    [api, folder, sortDir, sortKey, selectedIdsArray, selectedCount, runOptimisticRemoval, bulkLimitExceeded],
  );

  const markReadSelected = useCallback(() => runFlagOp(READ, selectedIdsArray, 'Marking read'), [runFlagOp, selectedIdsArray]);
  const markUnreadSelected = useCallback(() => runFlagOp(UNREAD, selectedIdsArray, 'Marking unread'), [runFlagOp, selectedIdsArray]);
  const flagSelected = useCallback(() => runFlagOp(FLAGGED, selectedIdsArray, 'Flagging'), [runFlagOp, selectedIdsArray]);

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
  const totalIds = total || visible.totalIds || messageIds.length;

  // A bulk op is mid-flight: the toolbar shows progress and its buttons are
  // disabled. Same DOM either way so the controls keep a stable footprint and
  // nothing the user could aim at shifts while chunks stream.
  const busy = bulkProgress !== null;
  const bulkPct = busy && bulkProgress.total
    ? Math.round((bulkProgress.done / bulkProgress.total) * 100)
    : 0;

  // --- Header -------------------------------------------------------------
  const renderHeader = () => {
    if (bulkMode) {
      return (
        <div className="msglist-header bulk" role="toolbar" aria-label="Bulk message actions">
          {busy ? (
            <div className="msglist-bulk-count msglist-bulk-progress" role="status" aria-live="polite">
              <span className="msglist-bulk-label">{bulkProgress.verb}</span>
              <span className="msglist-bulk-num">{bulkProgress.done.toLocaleString()}</span>
              <span className="msglist-bulk-label">of {bulkProgress.total.toLocaleString()}</span>
            </div>
          ) : (
            <div className="msglist-bulk-count">
              <span className="msglist-bulk-num">{selectedCount}</span>
              <span className="msglist-bulk-label">selected</span>
            </div>
          )}
          <div className="msglist-bulk-actions">
            <button type="button" className="tool-btn" onClick={archiveSelected} disabled={!selectedCount || busy}>
              <Icon name="archive" size={14} />
              <span className="tool-btn-label">Archive</span>
            </button>
            <div className="tool-btn-group">
              <button
                type="button"
                className="tool-btn"
                onClick={() => setShowMovePicker((v) => !v)}
                disabled={!selectedCount || busy}
                aria-haspopup="true"
                aria-expanded={showMovePicker}
              >
                <Icon name="move" size={14} />
                <span className="tool-btn-label">Move</span>
                <Icon name="chevron-down" size={12} />
              </button>
              {showMovePicker && !busy && (
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
            <button type="button" className="tool-btn" onClick={markReadSelected} disabled={!selectedCount || busy}>
              <Icon name="mark-read" size={14} />
              <span className="tool-btn-label">Mark read</span>
            </button>
            <button type="button" className="tool-btn" onClick={markUnreadSelected} disabled={!selectedCount || busy}>
              <Icon name="mark-unread" size={14} />
              <span className="tool-btn-label">Mark unread</span>
            </button>
            <button type="button" className="tool-btn" onClick={flagSelected} disabled={!selectedCount || busy}>
              <Icon name="flag" size={14} />
              <span className="tool-btn-label">Flag</span>
            </button>
            <button type="button" className="tool-btn danger" onClick={deleteSelected} disabled={!selectedCount || busy}>
              <Icon name="trash" size={14} />
              <span className="tool-btn-label">{isTrash ? 'Delete forever' : 'Delete'}</span>
            </button>
          </div>
          <button
            type="button"
            className="msglist-bulk-exit"
            onClick={exitBulk}
            disabled={busy}
            title="Exit bulk selection"
            aria-label="Exit bulk selection"
          >
            <Icon name="close" size={13} />
          </button>
          {busy && (
            <div
              className="msglist-bulk-progressbar"
              role="progressbar"
              aria-valuemin={0}
              aria-valuemax={bulkProgress.total}
              aria-valuenow={bulkProgress.done}
            >
              <span className="msglist-bulk-progressbar-fill" style={{ width: `${bulkPct}%` }} />
            </div>
          )}
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
          {['all', 'unread', 'flagged'].map((f) => {
            const count = pillCounts[f];
            return (
              <button
                key={f}
                type="button"
                role="tab"
                aria-selected={filter === f}
                className={`msglist-tab ${filter === f ? 'active' : ''}`}
                onClick={() => setFilter(f)}
              >
                <span className="msglist-tab-label">{f[0].toUpperCase() + f.slice(1)}</span>
                {typeof count === 'number' && (
                  <span className="msglist-tab-count">{count.toLocaleString()}</span>
                )}
              </button>
            );
          })}
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
      {initialLoading ? (
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
          flagPatch={flagPatch}
        />
      )}
      <ConfirmDialog
        open={confirmPurge}
        title="Delete forever?"
        message={
          <>
            {selectedCount === 1 ? 'This message' : `These ${selectedCount} messages`} will be
            permanently deleted. This can&rsquo;t be undone.
          </>
        }
        confirmLabel="Delete forever"
        cancelLabel="Cancel"
        destructive
        onConfirm={purgeSelected}
        onCancel={cancelPurge}
      />
    </div>
  );
}

export default Messages;
