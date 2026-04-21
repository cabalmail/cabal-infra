import React, {
  useCallback, useEffect, useMemo, useRef, useState,
} from 'react';
import {
  ChevronDown, ChevronRight, ChevronLeft, Star, Shuffle, Info, Plus,
} from 'lucide-react';
import { swatchFor } from '../../../utils/addressSwatch';
import useApi from '../../../hooks/useApi';
import './FromPicker.css';

const FAVORITES_KEY = 'cabalmail.compose.favorites.v1';
const USERNAME_RE = /^[a-z0-9][a-z0-9._-]*$/i;
const SUBDOMAIN_RE = /^[a-z0-9][a-z0-9-]*$/i;
const UNFILTERED_MORE_CAP = 12;
const FILTERED_SEARCH_CAP = 40;

function loadFavorites() {
  try {
    const raw = window.localStorage.getItem(FAVORITES_KEY);
    const parsed = raw ? JSON.parse(raw) : [];
    return new Set(Array.isArray(parsed) ? parsed : []);
  } catch {
    return new Set();
  }
}

function saveFavorites(set) {
  try {
    window.localStorage.setItem(FAVORITES_KEY, JSON.stringify([...set]));
  } catch {
    /* quota / disabled storage — favorites are non-critical */
  }
}

function randomString(length, first, middle, last) {
  let out = first.charAt(Math.floor(Math.random() * first.length));
  for (let i = 1; i < length - 1; i++) {
    out += middle.charAt(Math.floor(Math.random() * middle.length));
  }
  out += last.charAt(Math.floor(Math.random() * last.length));
  return out;
}

function highlightMatch(text, q) {
  if (!q) return text;
  const idx = text.toLowerCase().indexOf(q);
  if (idx === -1) return text;
  return (
    <>
      {text.slice(0, idx)}
      <mark className="from-picker__hl">{text.slice(idx, idx + q.length)}</mark>
      {text.slice(idx + q.length)}
    </>
  );
}

function FromRow({
  item, q, starred, active, onToggleStar, onPick, rowRef,
}) {
  return (
    <button
      type="button"
      ref={rowRef}
      role="option"
      aria-selected={active}
      className={`from-picker__option${active ? ' is-active' : ''}`}
      onClick={() => onPick(item.address)}
    >
      <span
        className="from-picker__swatch"
        style={{ background: swatchFor(item.address) }}
        aria-hidden="true"
      />
      <span className="from-picker__option-main">
        <span className="from-picker__option-addr">
          {highlightMatch(item.address, q)}
        </span>
        {item.comment && (
          <span className="from-picker__option-note">
            {highlightMatch(item.comment, q)}
          </span>
        )}
      </span>
      <span
        className={`from-picker__option-star${starred ? ' is-on' : ''}`}
        role="button"
        tabIndex={-1}
        aria-label={starred ? `Unfavorite ${item.address}` : `Favorite ${item.address}`}
        title={starred ? 'Remove from favorites' : 'Add to favorites'}
        onClick={(e) => { e.stopPropagation(); onToggleStar(item.address); }}
      >
        <Star
          size={13}
          fill={starred ? 'currentColor' : 'none'}
          aria-hidden="true"
        />
      </span>
    </button>
  );
}

function CreateForm({
  domains, initialUsername, onCancel, onSubmit, setMessage,
}) {
  const domainList = useMemo(() => (
    (domains || []).map((d) => d.domain).filter(Boolean)
  ), [domains]);
  const [user, setUser] = useState(initialUsername || '');
  const [sub, setSub] = useState('');
  const [domain, setDomain] = useState('');
  const [note, setNote] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const userRef = useRef(null);

  useEffect(() => {
    if (userRef.current) userRef.current.focus();
  }, []);

  const validUser = user && USERNAME_RE.test(user);
  const validSub = sub && SUBDOMAIN_RE.test(sub);
  const canSubmit = Boolean(validUser && validSub && domain) && !submitting;
  const preview = canSubmit ? `${user}@${sub}.${domain}` : '';

  const doRandom = () => {
    const alphanum = 'abcdefghijklmnopqrstuvwxyz0123456789';
    setUser(randomString(8, alphanum, alphanum + '._-', alphanum));
    setSub(randomString(8, alphanum, alphanum + '-', alphanum));
    if (domainList.length > 0) {
      setDomain(domainList[Math.floor(Math.random() * domainList.length)]);
    }
  };

  const doSubmit = async () => {
    if (!canSubmit) return;
    setSubmitting(true);
    try {
      await onSubmit({
        username: user, subdomain: sub, tld: domain,
        comment: note, address: preview,
      });
    } catch (err) {
      if (setMessage) setMessage('Could not create address. Try again.', true);
      setSubmitting(false);
      return;
    }
    setSubmitting(false);
  };

  const onKeyDown = (e) => {
    if (e.key === 'Enter' && canSubmit) {
      e.preventDefault();
      doSubmit();
    }
  };

  return (
    <div className="from-picker__create" onKeyDown={onKeyDown}>
      <div className="from-picker__create-head">
        <button
          type="button"
          className="from-picker__create-back"
          aria-label="Back to address list"
          onClick={onCancel}
        >
          <ChevronLeft size={14} aria-hidden="true" />
        </button>
        <div className="from-picker__create-titles">
          <div className="from-picker__create-title">New address</div>
          <div className="from-picker__create-sub">
            Cabalmail requires a subdomain for every address.
          </div>
        </div>
        <button
          type="button"
          className="from-picker__create-random"
          title="Generate a random address"
          onClick={doRandom}
        >
          <Shuffle size={13} aria-hidden="true" />
          <span>Random</span>
        </button>
      </div>

      <div className="from-picker__composer">
        {/*
          The three inputs look like a credentials form to password managers
          (1Password, LastPass, Bitwarden). The data-*-ignore attributes plus
          autoComplete="off" and a neutral name suppress autofill without
          relying on any single vendor's heuristic.
        */}
        <input
          ref={userRef}
          type="text"
          name="cabal-local-part"
          value={user}
          onChange={(e) => setUser(e.target.value.toLowerCase())}
          placeholder="username"
          aria-label="Username"
          className={`from-picker__ac-input${user && !validUser ? ' is-invalid' : ''}`}
          autoCapitalize="none" autoCorrect="off" spellCheck={false}
          autoComplete="off"
          data-1p-ignore="true"
          data-lpignore="true"
          data-bwignore="true"
          data-form-type="other"
        />
        <span className="from-picker__ac-sep">@</span>
        <input
          type="text"
          name="cabal-subdomain"
          value={sub}
          onChange={(e) => setSub(e.target.value.toLowerCase())}
          placeholder="subdomain"
          aria-label="Subdomain"
          className={`from-picker__ac-input${sub && !validSub ? ' is-invalid' : ''}`}
          autoCapitalize="none" autoCorrect="off" spellCheck={false}
          autoComplete="off"
          data-1p-ignore="true"
          data-lpignore="true"
          data-bwignore="true"
          data-form-type="other"
        />
        <span className="from-picker__ac-sep">.</span>
        <select
          name="cabal-domain"
          value={domain}
          onChange={(e) => setDomain(e.target.value)}
          aria-label="Domain"
          className="from-picker__ac-select"
          autoComplete="off"
          data-1p-ignore="true"
          data-lpignore="true"
          data-bwignore="true"
          data-form-type="other"
        >
          <option value="" disabled>
            {domainList.length === 0 ? '(no domains)' : 'domain'}
          </option>
          {domainList.map((d) => (
            <option key={d} value={d}>{d}</option>
          ))}
        </select>
      </div>

      <div className="from-picker__ac-preview-row">
        {preview ? (
          <>
            <span className="from-picker__ac-preview-label">Preview</span>
            <code className="from-picker__ac-preview">{preview}</code>
          </>
        ) : (
          <span className="from-picker__ac-preview-empty">
            Fill all three fields to see a preview
          </span>
        )}
      </div>

      <div className="from-picker__note-row">
        <label className="from-picker__note-label" htmlFor="from-picker-note">
          Note
        </label>
        <input
          id="from-picker-note"
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="e.g. florist down the street, gym sign-up, …"
          className="from-picker__note-input"
          maxLength={80}
        />
      </div>

      <div className="from-picker__hint-row">
        <Info size={12} aria-hidden="true" />
        <span>
          Notes are searchable — helpful when you have a lot of addresses.
        </span>
      </div>

      <div className="from-picker__create-actions">
        <button
          type="button"
          className="from-picker__btn"
          onClick={onCancel}
          disabled={submitting}
        >Cancel</button>
        <button
          type="button"
          className="from-picker__btn is-primary"
          onClick={doSubmit}
          disabled={!canSubmit}
        >{submitting ? 'Creating…' : 'Create & use'}</button>
      </div>
    </div>
  );
}

/**
 * Searchable From-address picker with inline "create a new address" flow.
 *
 * Props:
 *   items:       Array of DynamoDB address rows ({ address, comment, username,
 *                subdomain, tld, ... }). Unsorted input is fine.
 *   domains:     Array of { domain } objects — powers the Create flow.
 *   selected:    Currently selected address string, or ''.
 *   onSelect:    (address) => void — called when a row is picked.
 *   onCreated:   (address) => void — called after a successful inline create,
 *                *after* onSelect has already fired for the new address.
 *   stackIndex:  Compose window stack index, used only to namespace ids.
 *   setMessage:  Optional AppMessage writer for inline-create errors.
 */
function FromPicker({
  items, domains, selected, onSelect, onCreated, stackIndex = 0, setMessage,
}) {
  const api = useApi();
  const [open, setOpen] = useState(false);
  const [mode, setMode] = useState('pick'); // 'pick' | 'create'
  const [query, setQuery] = useState('');
  const [activeIdx, setActiveIdx] = useState(-1);
  const [favorites, setFavorites] = useState(loadFavorites);
  const rootRef = useRef(null);
  const inputRef = useRef(null);
  const rowsRef = useRef([]);

  const addresses = useMemo(() => (items || []), [items]);
  const q = query.trim().toLowerCase();

  const matches = useCallback((a) => {
    if (!q) return true;
    return a.address.toLowerCase().includes(q)
      || (a.comment || '').toLowerCase().includes(q)
      || (a.subdomain || '').toLowerCase().includes(q);
  }, [q]);

  const grouped = useMemo(() => {
    const fav = [];
    const rest = [];
    for (const a of addresses) {
      if (!matches(a)) continue;
      if (favorites.has(a.address)) fav.push(a); else rest.push(a);
    }
    const restCap = q ? FILTERED_SEARCH_CAP : UNFILTERED_MORE_CAP;
    const shownRest = rest.slice(0, restCap);
    return {
      fav,
      rest: shownRest,
      hiddenCount: rest.length - shownRest.length,
    };
  }, [addresses, favorites, matches, q]);

  const flat = useMemo(
    () => [...grouped.fav, ...grouped.rest],
    [grouped]
  );

  // Close on outside click.
  useEffect(() => {
    if (!open) return undefined;
    const onDoc = (e) => {
      if (rootRef.current && !rootRef.current.contains(e.target)) {
        setOpen(false);
        setMode('pick');
      }
    };
    document.addEventListener('mousedown', onDoc);
    return () => document.removeEventListener('mousedown', onDoc);
  }, [open]);

  // Autofocus search when the menu opens in pick mode.
  useEffect(() => {
    if (open && mode === 'pick' && inputRef.current) {
      inputRef.current.focus();
    }
  }, [open, mode]);

  // Reset keyboard cursor when the result shape changes.
  useEffect(() => { setActiveIdx(-1); }, [q, mode, open]);

  // Keep the active option scrolled into view when cursor changes.
  useEffect(() => {
    const row = rowsRef.current[activeIdx];
    if (row && row.scrollIntoView) {
      row.scrollIntoView({ block: 'nearest' });
    }
  }, [activeIdx]);

  const toggleFav = useCallback((address) => {
    setFavorites((prev) => {
      const next = new Set(prev);
      if (next.has(address)) next.delete(address); else next.add(address);
      saveFavorites(next);
      return next;
    });
  }, []);

  const closeMenu = useCallback(() => {
    setOpen(false);
    setMode('pick');
    setQuery('');
    setActiveIdx(-1);
  }, []);

  const pick = useCallback((address) => {
    if (onSelect) onSelect(address);
    closeMenu();
  }, [onSelect, closeMenu]);

  const onSearchKeyDown = useCallback((e) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setActiveIdx((i) => {
        if (flat.length === 0) return -1;
        return i + 1 >= flat.length ? 0 : i + 1;
      });
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setActiveIdx((i) => {
        if (flat.length === 0) return -1;
        return i <= 0 ? flat.length - 1 : i - 1;
      });
    } else if (e.key === 'Enter') {
      if (activeIdx >= 0 && activeIdx < flat.length) {
        e.preventDefault();
        pick(flat[activeIdx].address);
      }
    } else if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      closeMenu();
    }
  }, [flat, activeIdx, pick, closeMenu]);

  const submitCreate = useCallback(async ({
    username, subdomain, tld, comment, address,
  }) => {
    const resp = await api.newAddress(username, subdomain, tld, comment, address);
    const created = resp?.data?.address || address;
    if (setMessage) setMessage(`Created ${created}.`, false);
    if (onSelect) onSelect(created);
    if (onCreated) onCreated(created);
    closeMenu();
  }, [api, onSelect, onCreated, closeMenu, setMessage]);

  const selectedItem = addresses.find((a) => a.address === selected);
  const selectedSwatch = selected ? swatchFor(selected) : null;

  const nothingMatches = q && flat.length === 0;
  const seedUsername = (() => {
    if (!q) return '';
    if (q.includes('@')) return '';
    return USERNAME_RE.test(q) ? q : '';
  })();

  const triggerId = `from-picker-trigger-${stackIndex}`;
  const menuId = `from-picker-menu-${stackIndex}`;

  const favLabel = grouped.fav.length > 0 ? 'Favorites' : null;
  const restLabel = grouped.fav.length > 0 ? 'More addresses' : 'Your addresses';

  return (
    <div className="from-picker" ref={rootRef}>
      <button
        type="button"
        id={triggerId}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={menuId}
        className={`from-picker__trigger${open ? ' is-open' : ''}`}
        onClick={() => {
          if (open) { closeMenu(); return; }
          setOpen(true); setMode('pick');
        }}
      >
        {selectedSwatch && (
          <span
            className="from-picker__swatch from-picker__swatch--trigger"
            style={{ background: selectedSwatch }}
            aria-hidden="true"
          />
        )}
        <span className="from-picker__trigger-main">
          <span className="from-picker__trigger-addr">
            {selected || 'Select address'}
          </span>
          {selectedItem?.comment && (
            <span className="from-picker__trigger-note">
              {selectedItem.comment}
            </span>
          )}
        </span>
        <ChevronDown
          size={14}
          className="from-picker__caret"
          aria-hidden="true"
        />
      </button>

      {open && (
        <div
          id={menuId}
          className="from-picker__menu"
          role="dialog"
          aria-label="Choose a from address"
        >
          {mode === 'pick' ? (
            <>
              <div className="from-picker__search-row">
                <input
                  ref={inputRef}
                  type="search"
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  onKeyDown={onSearchKeyDown}
                  placeholder="Search your addresses…"
                  aria-label="Search your addresses"
                  aria-autocomplete="list"
                  aria-activedescendant={
                    activeIdx >= 0
                      ? `${menuId}-row-${activeIdx}`
                      : undefined
                  }
                  className="from-picker__search"
                />
              </div>

              <div className="from-picker__results" role="listbox">
                {grouped.fav.length > 0 && (
                  <div className="from-picker__section">
                    <div className="from-picker__section-label">
                      <span>{favLabel}</span>
                      <span className="from-picker__section-count">
                        {grouped.fav.length}
                      </span>
                    </div>
                    {grouped.fav.map((a, i) => (
                      <FromRow
                        key={a.address}
                        item={a}
                        q={q}
                        starred
                        active={activeIdx === i}
                        rowRef={(el) => { rowsRef.current[i] = el; }}
                        onToggleStar={toggleFav}
                        onPick={pick}
                      />
                    ))}
                  </div>
                )}

                {grouped.rest.length > 0 && (
                  <div className="from-picker__section">
                    <div className="from-picker__section-label">
                      <span>{restLabel}</span>
                      <span className="from-picker__section-count">
                        {grouped.rest.length}
                      </span>
                    </div>
                    {grouped.rest.map((a, i) => {
                      const idx = grouped.fav.length + i;
                      return (
                        <FromRow
                          key={a.address}
                          item={a}
                          q={q}
                          starred={favorites.has(a.address)}
                          active={activeIdx === idx}
                          rowRef={(el) => { rowsRef.current[idx] = el; }}
                          onToggleStar={toggleFav}
                          onPick={pick}
                        />
                      );
                    })}
                  </div>
                )}

                {!q && grouped.hiddenCount > 0 && (
                  <div className="from-picker__hint">
                    Type to search {grouped.hiddenCount} more address{grouped.hiddenCount === 1 ? '' : 'es'}
                  </div>
                )}

                {nothingMatches && (
                  <div className="from-picker__empty">
                    No address matches “{query}”.
                  </div>
                )}
              </div>

              <button
                type="button"
                className="from-picker__create-cta"
                onClick={() => setMode('create')}
              >
                <span className="from-picker__create-plus" aria-hidden="true">
                  <Plus size={12} />
                </span>
                <span className="from-picker__create-label">
                  <strong>Create a new address</strong>
                  <span className="from-picker__create-hint">
                    username @ subdomain . domain
                  </span>
                </span>
                <ChevronRight
                  size={14}
                  className="from-picker__create-chev"
                  aria-hidden="true"
                />
              </button>
            </>
          ) : (
            <CreateForm
              domains={domains}
              initialUsername={seedUsername}
              onCancel={() => setMode('pick')}
              onSubmit={submitCreate}
              setMessage={setMessage}
            />
          )}
        </div>
      )}
    </div>
  );
}

export default FromPicker;
