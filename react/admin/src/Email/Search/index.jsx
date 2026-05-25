/**
 * Search results pane. Replaces the folder Messages view when a search is
 * active. Phases 2 + 3 of `docs/0.9.x/imap-search-plan.md`. Cross-folder is
 * the default (the Lambda enumerates the user's subscribed folders and
 * excludes Trash on the server side); a "This folder only" toggle scopes
 * the search back to the currently-selected folder.
 *
 * Owns its own search state (the structured filters + the scope toggle) and
 * re-runs the query whenever the user submits the form. The free-text term
 * comes in via prop from the Nav search input; clearing search (Clear
 * button or empty query) lifts back up to App via `clearSearch`, which
 * switches the middle pane back to the folder view.
 *
 * Each result envelope carries a `folder` field from the Lambda naming its
 * source folder. Bulk archive / delete / flag and per-row swipe actions
 * group selected IDs by that folder so each backend call hits the right
 * mailbox, and the message overlay opens against `envelope.folder` so
 * its archive/delete/flag operations also target the correct folder.
 */
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { SwipeableList, Type } from 'react-swipeable-list';
import 'react-swipeable-list/dist/styles.css';
import { ArrowLeft, SlidersHorizontal, X } from 'lucide-react';
import Envelope from '../Messages/Envelope';
import Icon from '../Messages/icons';
import useApi from '../../hooks/useApi';
import { READ, UNREAD, FLAGGED } from '../../constants';
import './Search.css';

const DEFAULT_FILTERS = {
  from: '',
  to: '',
  subject: '',
  since: '',
  before: '',
  unread: false,
  flagged: false,
  has_attachment: false,
};

const PAGE_LIMIT = 50;

function activeFilterCount(filters) {
  let n = 0;
  for (const key of Object.keys(DEFAULT_FILTERS)) {
    const value = filters[key];
    if (typeof value === 'boolean' ? value : (value || '').trim() !== '') n += 1;
  }
  return n;
}

function Search({
  folder,
  query,
  clearSearch,
  showOverlay,
  selected,
  setSelected,
  bulkMode,
  setBulkMode,
  layout = 'desktop',
  onOpenDrawer,
}) {
  const api = useApi();

  // `filters` is the live form state — edited as the user types. It does
  // not drive fetches by itself: the user has to click Apply, which copies
  // it into `submittedFilters`. That snapshot is what the fetch effect
  // depends on, so keystrokes inside the filter panel don't hammer the
  // Lambda.
  const [filters, setFilters] = useState(DEFAULT_FILTERS);
  const [submittedFilters, setSubmittedFilters] = useState(DEFAULT_FILTERS);
  const [filtersOpen, setFiltersOpen] = useState(false);
  // Scope toggle: cross-folder is the default (sends no `folder` param,
  // Lambda enumerates the user's subscribed folders). Flipping it on
  // scopes the search to the currently-selected folder. Lives outside
  // `submittedFilters` because flipping it should re-fetch immediately,
  // not wait for the user to open the filter panel and click Apply.
  const [thisFolderOnly, setThisFolderOnly] = useState(false);
  // `refreshTick` bumps to force a re-fetch after a mutation (archive,
  // flag, delete) without needing the user to re-submit anything.
  const [refreshTick, setRefreshTick] = useState(0);
  const [envelopes, setEnvelopes] = useState([]);
  const [totalEstimate, setTotalEstimate] = useState(0);
  const [truncated, setTruncated] = useState(false);
  const [nextCursor, setNextCursor] = useState(null);
  const [foldersSearched, setFoldersSearched] = useState([]);
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState(null);

  const lastSelectedRef = useRef(null);

  // Reset selection when the search context changes — same reasoning as
  // Messages clearing selection on folder/filter switches.
  useEffect(() => {
    setSelected(new Set());
    lastSelectedRef.current = null;
  }, [folder, query, submittedFilters, thisFolderOnly, setSelected]);

  const buildParams = useCallback((cursor, filterSnapshot) => {
    const f = filterSnapshot || submittedFilters;
    const params = { text: query, limit: PAGE_LIMIT };
    // Cross-folder is the Lambda default (no `folder` param). Only include
    // `folder` when the user has explicitly scoped the search.
    if (thisFolderOnly) params.folder = folder;
    if (cursor) params.cursor = cursor;
    if (f.from.trim()) params.from = f.from.trim();
    if (f.to.trim()) params.to = f.to.trim();
    if (f.subject.trim()) params.subject = f.subject.trim();
    if (f.since) params.since = f.since;
    if (f.before) params.before = f.before;
    if (f.unread) params.unread = true;
    if (f.flagged) params.flagged = true;
    if (f.has_attachment) params.has_attachment = true;
    return params;
  }, [folder, query, submittedFilters, thisFolderOnly]);

  // Fetch fires on mount and any time the committed query inputs change.
  // Typing in the filter form does NOT trigger a fetch — only Apply does
  // (which copies `filters` into `submittedFilters`).
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    setEnvelopes([]);
    setNextCursor(null);
    setTruncated(false);
    setTotalEstimate(0);
    setFoldersSearched([]);

    api
      .searchEnvelopes(buildParams(null))
      .then((res) => {
        if (cancelled) return;
        const data = res.data || {};
        setEnvelopes(Array.isArray(data.envelopes) ? data.envelopes : []);
        setTotalEstimate(data.total_estimate || 0);
        setTruncated(!!data.truncated);
        setNextCursor(data.next_cursor || null);
        setFoldersSearched(data.folders_searched || []);
        setLoading(false);
      })
      .catch((e) => {
        if (cancelled) return;
        console.error(e);
        setError('Search failed. Try again.');
        setLoading(false);
      });

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [api, folder, query, submittedFilters, thisFolderOnly, refreshTick]);

  const loadMore = useCallback(() => {
    if (!nextCursor || loadingMore) return;
    setLoadingMore(true);
    api
      .searchEnvelopes(buildParams(nextCursor))
      .then((res) => {
        const data = res.data || {};
        setEnvelopes((prev) => prev.concat(data.envelopes || []));
        setNextCursor(data.next_cursor || null);
        setLoadingMore(false);
      })
      .catch((e) => {
        console.error(e);
        setLoadingMore(false);
      });
  }, [api, buildParams, nextCursor, loadingMore]);

  const refreshAfterMutation = useCallback(() => {
    setRefreshTick((t) => t + 1);
  }, []);

  const updateFilter = useCallback((name, value) => {
    setFilters((prev) => ({ ...prev, [name]: value }));
  }, []);

  const handleSubmitFilters = useCallback((e) => {
    if (e && typeof e.preventDefault === 'function') e.preventDefault();
    setSubmittedFilters(filters);
  }, [filters]);

  const handleResetFilters = useCallback(() => {
    setFilters(DEFAULT_FILTERS);
    setSubmittedFilters(DEFAULT_FILTERS);
  }, []);

  const exitBulk = useCallback(() => {
    setBulkMode(false);
    setSelected(new Set());
    lastSelectedRef.current = null;
  }, [setBulkMode, setSelected]);

  const selectedIdsArray = useMemo(() => Array.from(selected), [selected]);
  const selectedCount = selected.size;

  // Per-result source folder map. Results from cross-folder search carry
  // their own `folder`; single-folder results fall back to the page folder.
  // Operations look up the right source folder per ID so the backend call
  // hits the mailbox that actually holds the message.
  const folderById = useMemo(() => {
    const m = new Map();
    for (const e of envelopes) {
      m.set(Number(e.id), e.folder || folder);
    }
    return m;
  }, [envelopes, folder]);

  const groupByFolder = useCallback((ids) => {
    const groups = new Map();
    for (const id of ids) {
      const f = folderById.get(Number(id)) || folder;
      if (!groups.has(f)) groups.set(f, []);
      groups.get(f).push(Number(id));
    }
    return groups;
  }, [folderById, folder]);

  const runFlagOp = useCallback((spec, ids) => {
    if (!ids.length) return;
    const groups = groupByFolder(ids);
    const calls = [];
    for (const [src, groupIds] of groups.entries()) {
      calls.push(api.setFlag(src, spec.imap, spec.op, groupIds));
    }
    Promise.all(calls)
      .then(refreshAfterMutation)
      .catch((err) => console.error(err));
  }, [api, groupByFolder, refreshAfterMutation]);

  const moveSelectedTo = useCallback((destination) => {
    if (!selectedCount) return;
    const groups = groupByFolder(selectedIdsArray);
    const calls = [];
    for (const [src, ids] of groups.entries()) {
      calls.push(api.moveMessages(src, destination, ids));
    }
    Promise.all(calls)
      .then(() => {
        refreshAfterMutation();
        exitBulk();
      })
      .catch((err) => console.error(err));
  }, [api, groupByFolder, selectedIdsArray, selectedCount, refreshAfterMutation, exitBulk]);

  const archiveSelected = useCallback(() => moveSelectedTo('Archive'), [moveSelectedTo]);
  const deleteSelected = useCallback(() => moveSelectedTo('Deleted Messages'), [moveSelectedTo]);

  const markReadSelected = useCallback(() => runFlagOp(READ, selectedIdsArray), [runFlagOp, selectedIdsArray]);
  const markUnreadSelected = useCallback(() => runFlagOp(UNREAD, selectedIdsArray), [runFlagOp, selectedIdsArray]);
  const flagSelected = useCallback(() => runFlagOp(FLAGGED, selectedIdsArray), [runFlagOp, selectedIdsArray]);

  // Single-row swipe ops mirror Messages but resolve each row's source
  // folder so cross-folder results route to the right mailbox.
  const folderFor = useCallback(
    (id) => folderById.get(Number(id)) || folder,
    [folderById, folder],
  );
  const markReadOne = useCallback(
    (id) => api.setFlag(folderFor(id), READ.imap, READ.op, [id]).then(refreshAfterMutation).catch((e) => console.error(e)),
    [api, folderFor, refreshAfterMutation],
  );
  const markUnreadOne = useCallback(
    (id) => api.setFlag(folderFor(id), UNREAD.imap, UNREAD.op, [id]).then(refreshAfterMutation).catch((e) => console.error(e)),
    [api, folderFor, refreshAfterMutation],
  );
  const archiveOne = useCallback(
    (id) => {
      const src = folderFor(id);
      return api
        .setFlag(src, READ.imap, READ.op, [id])
        .then(() => api.moveMessages(src, 'Archive', [id]))
        .then(refreshAfterMutation)
        .catch((e) => console.error(e));
    },
    [api, folderFor, refreshAfterMutation],
  );

  // Optimistic local flag toggle so the row reflects changes immediately
  // while the next refresh is still in flight.
  const applyLocalFlag = useCallback((id, mutator) => {
    setEnvelopes((prev) => prev.map((env) => (Number(env.id) === Number(id) ? mutator(env) : env)));
  }, []);

  const markRead = useCallback(
    (id) => {
      applyLocalFlag(id, (env) => (env.flags.includes('\\Seen') ? env : { ...env, flags: [...env.flags, '\\Seen'] }));
      markReadOne(id);
    },
    [applyLocalFlag, markReadOne],
  );
  const markUnread = useCallback(
    (id) => {
      applyLocalFlag(id, (env) => ({ ...env, flags: env.flags.filter((f) => f !== '\\Seen') }));
      markUnreadOne(id);
    },
    [applyLocalFlag, markUnreadOne],
  );
  const archive = useCallback((id) => archiveOne(id), [archiveOne]);

  const shownIds = useMemo(() => envelopes.map((e) => Number(e.id)), [envelopes]);

  const toggleSelect = useCallback(
    (id, { shift, meta } = {}) => {
      const next = new Set(selected);
      if (shift && lastSelectedRef.current != null && shownIds.length) {
        const a = shownIds.indexOf(Number(lastSelectedRef.current));
        const b = shownIds.indexOf(Number(id));
        if (a !== -1 && b !== -1) {
          const [lo, hi] = a < b ? [a, b] : [b, a];
          for (let i = lo; i <= hi; i += 1) next.add(shownIds[i]);
        } else {
          next.add(Number(id));
        }
      } else {
        const num = Number(id);
        if (next.has(num)) next.delete(num);
        else next.add(num);
      }
      setSelected(next);
      lastSelectedRef.current = Number(id);
      if (!bulkMode && next.size > 0) setBulkMode(true);
    },
    [selected, setSelected, shownIds, bulkMode, setBulkMode],
  );

  const handleClick = useCallback(
    (envelope, id) => {
      showOverlay(envelope);
      lastSelectedRef.current = Number(id);
    },
    [showOverlay],
  );

  const filtersActive = activeFilterCount(filters);
  const scopeLabel = thisFolderOnly
    ? (foldersSearched[0] || folder)
    : (foldersSearched.length > 0
        ? `${foldersSearched.length} ${foldersSearched.length === 1 ? 'folder' : 'folders'}`
        : 'all folders');
  const scopeTitle = thisFolderOnly ? null : (foldersSearched.join(', ') || null);

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
      <div className="search-header">
        <div className="search-title-row">
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
          <h1 className="search-title">
            <span className="search-title-label">Search</span>
            {query && <span className="search-title-query" title={query}>{query}</span>}
          </h1>
          <button
            type="button"
            className="search-clear"
            onClick={() => clearSearch && clearSearch()}
            aria-label="Clear search"
            title="Clear search"
          >
            <X size={16} aria-hidden="true" />
          </button>
        </div>
        <div className="search-meta">
          <span className="search-scope" title={scopeTitle || undefined}>
            in <strong>{scopeLabel}</strong>
          </span>
          {!loading && (
            <span className="search-count">
              {truncated
                ? `Showing first ${envelopes.length} of approximately ${totalEstimate}+ matches — refine your query`
                : `${envelopes.length} of ${totalEstimate} ${totalEstimate === 1 ? 'match' : 'matches'}`}
            </span>
          )}
          <button
            type="button"
            className={`search-filter-toggle${filtersActive > 0 ? ' has-active' : ''}`}
            onClick={() => setFiltersOpen((v) => !v)}
            aria-expanded={filtersOpen}
            aria-controls="search-filter-panel"
          >
            <SlidersHorizontal size={13} aria-hidden="true" />
            <span>Filters</span>
            {filtersActive > 0 && <span className="search-filter-badge">{filtersActive}</span>}
          </button>
        </div>
        {filtersOpen && (
          <form
            id="search-filter-panel"
            className="search-filters"
            onSubmit={handleSubmitFilters}
            aria-label="Refine search"
          >
            <label className="search-field">
              <span>From</span>
              <input
                type="text"
                value={filters.from}
                onChange={(e) => updateFilter('from', e.target.value)}
                placeholder="sender@example.com"
              />
            </label>
            <label className="search-field">
              <span>To</span>
              <input
                type="text"
                value={filters.to}
                onChange={(e) => updateFilter('to', e.target.value)}
                placeholder="recipient@example.com"
              />
            </label>
            <label className="search-field search-field--wide">
              <span>Subject</span>
              <input
                type="text"
                value={filters.subject}
                onChange={(e) => updateFilter('subject', e.target.value)}
                placeholder="invoice"
              />
            </label>
            <label className="search-field">
              <span>Since</span>
              <input
                type="date"
                value={filters.since}
                onChange={(e) => updateFilter('since', e.target.value)}
              />
            </label>
            <label className="search-field">
              <span>Before</span>
              <input
                type="date"
                value={filters.before}
                onChange={(e) => updateFilter('before', e.target.value)}
              />
            </label>
            <div className="search-checks">
              <label className="search-check">
                <input
                  type="checkbox"
                  checked={filters.unread}
                  onChange={(e) => updateFilter('unread', e.target.checked)}
                />
                <span>Unread</span>
              </label>
              <label className="search-check">
                <input
                  type="checkbox"
                  checked={filters.flagged}
                  onChange={(e) => updateFilter('flagged', e.target.checked)}
                />
                <span>Flagged</span>
              </label>
              <label className="search-check">
                <input
                  type="checkbox"
                  checked={filters.has_attachment}
                  onChange={(e) => updateFilter('has_attachment', e.target.checked)}
                />
                <span>Has attachment</span>
              </label>
              <label
                className="search-check"
                title={`Scope to ${folder} only; otherwise search every subscribed folder except Trash.`}
              >
                <input
                  type="checkbox"
                  checked={thisFolderOnly}
                  onChange={(e) => setThisFolderOnly(e.target.checked)}
                />
                <span>This folder only</span>
              </label>
            </div>
            <div className="search-actions">
              <button type="button" className="search-btn" onClick={handleResetFilters}>
                Reset
              </button>
              <button type="submit" className="search-btn search-btn--primary">
                Apply
              </button>
            </div>
          </form>
        )}
      </div>
    );
  };

  return (
    <div className={`msglist search-pane ${bulkMode ? 'select-mode' : ''}`}>
      <div className="msglist-sticky">{renderHeader()}</div>
      {loading ? (
        <div className="msglist-loading" role="status" aria-label="Searching">
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
          <span className="sr-only">Searching...</span>
        </div>
      ) : error ? (
        <div className="search-empty" role="alert">
          <span className="search-empty-line">{error}</span>
        </div>
      ) : envelopes.length === 0 ? (
        <div className="search-empty" role="status">
          <span className="search-empty-line">No messages match your search.</span>
          <span className="search-empty-hint">Try a different term or relax your filters.</span>
        </div>
      ) : (
        <>
          <SwipeableList fullSwipe={true} type={Type.IOS} className={`envelope-list ${bulkMode ? 'bulk-mode' : ''}`}>
            {envelopes.map((e) => {
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
                  folder={!thisFolderOnly && e.folder ? e.folder : null}
                  is_checked={selected.has(id)}
                  dom_id={e.id}
                  bulkMode={bulkMode}
                  selected={false}
                  observer={null}
                />
              );
            })}
          </SwipeableList>
          {nextCursor && (
            <div className="search-more">
              <button
                type="button"
                className="search-btn search-btn--primary"
                onClick={loadMore}
                disabled={loadingMore}
              >
                {loadingMore ? 'Loading...' : 'Load more results'}
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}

export default Search;
