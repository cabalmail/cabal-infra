import React, { useState, useCallback, useEffect, useMemo } from 'react';
import Observer from './Observer';
import { SwipeableList, Type } from 'react-swipeable-list';
import 'react-swipeable-list/dist/styles.css';
import Envelope from './Envelope';
import useApi from '../../hooks/useApi';
import { PAGE_SIZE } from '../../constants';
import './Envelopes.css';

function matchesFilter(envelope, filter) {
  if (!envelope) return false;
  if (filter === 'unread') return !envelope.flags.includes('\\Seen');
  if (filter === 'flagged') return envelope.flags.includes('\\Flagged');
  return true;
}

function matchesAddress(envelope, addressFilter) {
  if (!addressFilter) return true;
  const needle = addressFilter.toLowerCase();
  const recipients = [].concat(envelope.to || [], envelope.cc || []);
  return recipients.some((r) => String(r || '').toLowerCase().includes(needle));
}

function Envelopes({
  message_ids,
  folder,
  showOverlay,
  selected,
  setSelected,
  lastSelectedRef,
  bulkMode,
  setBulkMode,
  filter,
  addressFilter,
  emptyLabel,
  onVisibleEnvelopesChange,
  markUnread: markUnreadProp,
  markRead: markReadProp,
  archive: archiveProp,
}) {
  const api = useApi();

  const [envelopes, setEnvelopes] = useState({});
  const [pages, setPages] = useState([]);

  const loadPages = useCallback((pageNums) => {
    setPages((currentPages) => {
      setEnvelopes((prev) => {
        let merged = { ...prev };
        for (const p of pageNums) {
          if (currentPages[p]) {
            merged = { ...merged, ...currentPages[p] };
          }
        }
        return merged;
      });
      return currentPages;
    });
  }, []);

  // Fetch envelopes when message_ids change
  useEffect(() => {
    let cancelled = false;
    const numIds = message_ids.length;

    for (let i = 0; i < numIds; i += PAGE_SIZE) {
      const ids = message_ids.slice(i, i + PAGE_SIZE);
      const page = Math.floor(i / PAGE_SIZE);

      api.getEnvelopes(folder, ids).then((data) => {
        if (cancelled) return;

        setPages((prev) => {
          const next = prev.slice();
          next[page] = data.data.envelopes;
          return next;
        });

        if (page < 4) {
          setEnvelopes((prev) => ({
            ...prev,
            ...data.data.envelopes,
          }));
        }
      }).catch((e) => {
        console.log(e);
      });
    }

    return () => {
      cancelled = true;
    };
  }, [api, folder, message_ids]);

  // Clear envelopes and pages when folder changes so stale data doesn't leak.
  useEffect(() => {
    setEnvelopes({});
    setPages([]);
  }, [folder]);

  const shownIds = useMemo(() => {
    const list = [];
    for (const id of message_ids) {
      const env = envelopes[id.toString()];
      if (!env) continue;
      if (!matchesAddress(env, addressFilter)) continue;
      if (!matchesFilter(env, filter)) continue;
      list.push(id);
    }
    return list;
  }, [message_ids, envelopes, filter, addressFilter]);

  // Tell parent what's currently visible (for header "N of M" + pill counts)
  useEffect(() => {
    if (typeof onVisibleEnvelopesChange !== 'function') return;
    const loaded = [];
    for (const id of message_ids) {
      const env = envelopes[id.toString()];
      if (env) loaded.push(env);
    }
    onVisibleEnvelopesChange({
      loaded,
      totalIds: message_ids.length,
      shownIds,
    });
  }, [message_ids, envelopes, shownIds, onVisibleEnvelopesChange]);

  const toggleSelect = useCallback(
    (id, { shift, meta } = {}) => {
      const next = new Set(selected);
      if (shift && lastSelectedRef.current != null && shownIds.length) {
        const a = shownIds.indexOf(Number(lastSelectedRef.current));
        const b = shownIds.indexOf(Number(id));
        if (a !== -1 && b !== -1) {
          const [lo, hi] = a < b ? [a, b] : [b, a];
          for (let i = lo; i <= hi; i++) next.add(shownIds[i]);
        } else {
          next.add(Number(id));
        }
      } else if (meta) {
        const num = Number(id);
        if (next.has(num)) next.delete(num);
        else next.add(num);
      } else {
        const num = Number(id);
        if (next.has(num)) next.delete(num);
        else next.add(num);
      }
      setSelected(next);
      lastSelectedRef.current = Number(id);
      if (!bulkMode && next.size > 0) setBulkMode(true);
    },
    [selected, setSelected, shownIds, lastSelectedRef, bulkMode, setBulkMode],
  );

  const handleClick = useCallback(
    (envelope, id) => {
      showOverlay(envelope);
      lastSelectedRef.current = Number(id);
    },
    [showOverlay, lastSelectedRef],
  );

  const markRead = useCallback(
    (id) => {
      setEnvelopes((prev) => {
        const key = id.toString();
        const envelope = prev[key];
        if (!envelope || envelope.flags.includes('\\Seen')) return prev;
        const next = { ...prev, [key]: { ...envelope, flags: [...envelope.flags, '\\Seen'] } };
        return next;
      });
      markReadProp(id);
    },
    [markReadProp],
  );

  const markUnread = useCallback(
    (id) => {
      setEnvelopes((prev) => {
        const key = id.toString();
        const envelope = prev[key];
        if (!envelope) return prev;
        const flags = envelope.flags.filter((f) => f !== '\\Seen');
        return { ...prev, [key]: { ...envelope, flags } };
      });
      markUnreadProp(id);
    },
    [markUnreadProp],
  );

  const archive = useCallback((id) => archiveProp(id), [archiveProp]);

  const rows = shownIds.map((k, idx) => {
    const e = envelopes[k.toString()];
    let observer = null;
    const page = Math.floor(idx / PAGE_SIZE);
    if (idx % PAGE_SIZE === 0) {
      observer = <Observer pageLoader={loadPages} page={page + 2} key={page + 2} />;
    }
    const id = Number(e.id);
    return (
      <Envelope
        key={e.id}
        handleClick={handleClick}
        toggleSelect={toggleSelect}
        archive={archive}
        markRead={markRead}
        markUnread={markUnread}
        envelope={e}
        subject={e.subject}
        priority={e.priority}
        date={e.date}
        from={e.from}
        flags={e.flags}
        struct={e.struct}
        is_checked={selected.has(id)}
        dom_id={e.id}
        bulkMode={bulkMode}
        selected={false}
        observer={observer}
      />
    );
  });

  if (rows.length === 0) {
    return (
      <div className={`envelopes-empty ${bulkMode ? 'in-bulk' : ''}`} role="status">
        <span className="envelopes-empty-line">{emptyLabel || 'Inbox zero.'}</span>
        {(filter !== 'all' || addressFilter) && (
          <span className="envelopes-empty-hint">Clear filter to see more →</span>
        )}
      </div>
    );
  }

  return (
    <SwipeableList fullSwipe={true} type={Type.IOS} className={`envelope-list ${bulkMode ? 'bulk-mode' : ''}`}>
      {rows}
    </SwipeableList>
  );
}

export default Envelopes;
