import React, { useState, useCallback, useEffect, useLayoutEffect, useMemo, useRef } from 'react';
import { SwipeableList, Type } from 'react-swipeable-list';
import 'react-swipeable-list/dist/styles.css';
import Envelope from './Envelope';
import useApi from '../../hooks/useApi';
import { fetchBimi } from '../../utils/bimiCache';
import { PAGE_SIZE } from '../../constants';
import './Envelopes.css';

// Pages fetched up front to fill the first viewport before scroll-driven lazy
// loading takes over.
const INITIAL_PAGES = 3;
// Rows rendered above/below the viewport so a fast scroll doesn't flash blank.
const OVERSCAN = 10;

// Pure window math, exported for tests. Given the scroll offset, viewport and
// row height, returns the [start, end) slice of `total` rows to render. When
// height isn't known yet (first paint, or jsdom with no layout) it returns the
// whole list so nothing is hidden -- virtualization only kicks in once we can
// measure.
export function computeWindow(scrollTop, viewportHeight, rowHeight, total, overscan = OVERSCAN) {
  if (!(rowHeight > 0) || !(viewportHeight > 0) || total === 0) {
    return { start: 0, end: total };
  }
  const first = Math.floor(scrollTop / rowHeight);
  const visible = Math.ceil(viewportHeight / rowHeight);
  const start = Math.max(0, first - overscan);
  const end = Math.min(total, first + visible + overscan);
  return { start, end };
}

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
  flagPatch = null,
}) {
  const api = useApi();

  // Stable per-domain BIMI resolver passed to each row; the session cache
  // coalesces concurrent lookups and memoizes results across row recycling.
  const getBimi = useCallback((domain) => fetchBimi(api, domain), [api]);

  const [envelopes, setEnvelopes] = useState({});
  // Refs, not state: these gate fetches, they don't drive rendering.
  // `fetchedPagesRef` dedupes requests; `frontierRef` is the highest page the
  // lazy loader has reached so far.
  const fetchedPagesRef = useRef(new Set());
  const frontierRef = useRef(-1);

  const fetchPage = useCallback(
    (pageNum, { refresh = false } = {}) => {
      const start = pageNum * PAGE_SIZE;
      if (pageNum < 0 || start >= message_ids.length) return;
      if (!refresh && fetchedPagesRef.current.has(pageNum)) return;
      fetchedPagesRef.current.add(pageNum);
      const ids = message_ids.slice(start, start + PAGE_SIZE);
      api
        .getEnvelopes(folder, ids)
        .then((data) => {
          setEnvelopes((prev) => ({ ...prev, ...data.data.envelopes }));
        })
        .catch((e) => {
          if (!refresh) fetchedPagesRef.current.delete(pageNum); // allow retry
          console.log(e);
        });
    },
    [api, folder, message_ids],
  );

  // Clear caches when the folder changes so stale data doesn't leak.
  useEffect(() => {
    setEnvelopes({});
    fetchedPagesRef.current = new Set();
    frontierRef.current = -1;
  }, [folder]);

  // Apply a bulk flag change from the parent optimistically, the same way the
  // single-row markRead/markUnread paths do -- so a bulk "mark read" updates
  // the read dots (and drops rows out of the Unread filter) instantly, without
  // the parent re-pulling the whole UID list. Each patch carries a fresh `seq`
  // so a repeat of the same op (mark read, then mark read again) still fires,
  // and a failed op sends the inverse patch to roll the flags back.
  useEffect(() => {
    if (!flagPatch) return;
    const { ids, flag, op } = flagPatch;
    setEnvelopes((prev) => {
      let changed = false;
      const next = { ...prev };
      for (const id of ids) {
        const key = id.toString();
        const env = next[key];
        if (!env) continue;
        const has = env.flags.includes(flag);
        if (op === 'set' && !has) {
          next[key] = { ...env, flags: [...env.flags, flag] };
          changed = true;
        } else if (op === 'unset' && has) {
          next[key] = { ...env, flags: env.flags.filter((f) => f !== flag) };
          changed = true;
        }
      }
      return changed ? next : prev;
    });
  }, [flagPatch]);

  // First pass fills the opening viewport; later passes (the parent re-polls
  // /list_messages every 10s, handing down a fresh array) refresh only the
  // pages already loaded -- to pick up flag changes and new top-of-folder
  // messages -- instead of re-fanning out the entire folder every poll.
  useEffect(() => {
    if (message_ids.length === 0) return;
    if (fetchedPagesRef.current.size === 0) {
      const totalPages = Math.ceil(message_ids.length / PAGE_SIZE);
      const last = Math.min(INITIAL_PAGES, totalPages) - 1;
      for (let p = 0; p <= last; p++) fetchPage(p);
      frontierRef.current = last;
    } else {
      for (const p of Array.from(fetchedPagesRef.current)) {
        fetchPage(p, { refresh: true });
      }
    }
  }, [message_ids, fetchPage]);

  const loadMore = useCallback(() => {
    const next = frontierRef.current + 1;
    if (next * PAGE_SIZE >= message_ids.length) return;
    frontierRef.current = next;
    fetchPage(next);
  }, [message_ids, fetchPage]);

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

  // --- Virtualization --------------------------------------------------
  // Render only the rows in (and near) the viewport. SwipeableList forwards
  // `style` but its items don't, so we window by padding the list top/bottom
  // for the off-screen rows rather than absolutely positioning each one.
  const scrollRef = useRef(null);
  const rafRef = useRef(0);
  const [scrollTop, setScrollTop] = useState(0);
  const [rowHeight, setRowHeight] = useState(0);
  const [viewportH, setViewportH] = useState(0);

  // Measure a real row's height and the viewport once rows exist (and whenever
  // the rendered count changes). Guarded sets keep this from looping.
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const vh = el.clientHeight;
    if (vh > 0) setViewportH((prev) => (prev !== vh ? vh : prev));
    const item = el.querySelector('.swipeable-list-item');
    if (item && item.offsetHeight > 0) {
      const h = item.offsetHeight;
      setRowHeight((prev) => (prev !== h ? h : prev));
    }
  }, [shownIds.length]);

  // Keep the viewport height current across pane resizes. Keyed to the row
  // count so it (re)attaches once the scroll element actually exists -- the
  // empty state renders no scroll container.
  useEffect(() => {
    const el = scrollRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return undefined;
    const ro = new ResizeObserver(() => {
      if (el.clientHeight > 0) setViewportH(el.clientHeight);
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [shownIds.length]);

  const onScroll = useCallback(() => {
    const el = scrollRef.current;
    if (!el) return;
    if (rafRef.current) cancelAnimationFrame(rafRef.current);
    rafRef.current = requestAnimationFrame(() => {
      rafRef.current = 0;
      setScrollTop(el.scrollTop);
      // Pull the next lazy page in as the bottom of the loaded list nears.
      const slack = rowHeight > 0 ? rowHeight * 6 : 300;
      if (el.scrollHeight - (el.scrollTop + el.clientHeight) < slack) loadMore();
    });
  }, [rowHeight, loadMore]);

  useEffect(() => () => {
    if (rafRef.current) cancelAnimationFrame(rafRef.current);
  }, []);

  const { start, end } = computeWindow(scrollTop, viewportH, rowHeight, shownIds.length);
  // Drive the scroll height from an explicit sizer and offset the visible rows
  // with a transform. The sizer's height only grows (as more loads), never
  // shrinks as the window moves -- so the browser never clamps scrollTop back
  // mid-scroll, which a padding-based height would do and strand the rows.
  const virtualized = rowHeight > 0;
  const offsetY = virtualized ? start * rowHeight : 0;
  const totalHeight = virtualized ? shownIds.length * rowHeight : undefined;

  // Tell parent what's currently visible (for header "N of M")
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

  const rows = shownIds.slice(start, end).map((k) => {
    const e = envelopes[k.toString()];
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
        getBimi={getBimi}
      />
    );
  });

  if (shownIds.length === 0) {
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
    <div className="envelope-scroll" ref={scrollRef} onScroll={onScroll}>
      <div className="envelope-sizer" style={virtualized ? { height: totalHeight } : undefined}>
        <div
          className="envelope-window"
          style={virtualized ? { transform: `translateY(${offsetY}px)` } : undefined}
        >
          <SwipeableList
            fullSwipe={true}
            type={Type.IOS}
            className={`envelope-list ${bulkMode ? 'bulk-mode' : ''}`}
          >
            {rows}
          </SwipeableList>
        </div>
      </div>
    </div>
  );
}

export default Envelopes;
