import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Copy, Plus, Search, Star, X } from 'lucide-react';
import useApi from '../hooks/useApi';
import { ADDRESS_LIST } from '../constants';
import ConfirmDialog from '../ConfirmDialog';
import Request from './Request';
import './Addresses.css';

function sortAddresses(items) {
  return items.slice().sort((a, b) => {
    if (a.address > b.address) return 1;
    if (a.address < b.address) return -1;
    return 0;
  });
}

function AddressRow({
  a, isActive, isFavorite, onSelect, onToggleFavorite, onCopy, onRevoke,
}) {
  return (
    <li
      className={`addresses-rail__row${isActive ? ' is-active' : ''}`}
      title={a.comment ? undefined : a.address}
      data-address={a.address}
      data-comment={a.comment || undefined}
      onClick={() => onSelect(a.address)}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => { if (e.key === 'Enter') onSelect(a.address); }}
      aria-current={isActive ? 'true' : undefined}
    >
      <span className="addresses-rail__address">{a.address}</span>
      <span className="addresses-rail__row-actions" onClick={(e) => e.stopPropagation()}>
        <button
          type="button"
          className={`addresses-rail__row-action${isFavorite ? ' is-on' : ''}`}
          title={isFavorite ? 'Remove from favorites' : 'Add to favorites'}
          aria-label={isFavorite ? `Unfavorite ${a.address}` : `Favorite ${a.address}`}
          onClick={(e) => onToggleFavorite(e, a)}
        >
          <Star size={12} fill={isFavorite ? 'currentColor' : 'none'} aria-hidden="true" />
        </button>
        <button
          type="button"
          className="addresses-rail__row-action"
          title="Copy address"
          aria-label={`Copy ${a.address}`}
          onClick={(e) => onCopy(e, a)}
        >
          <Copy size={12} aria-hidden="true" />
        </button>
        <button
          type="button"
          className="addresses-rail__row-action"
          title="Revoke address"
          aria-label={`Revoke ${a.address}`}
          onClick={(e) => onRevoke(e, a)}
        >
          <X size={12} aria-hidden="true" />
        </button>
      </span>
    </li>
  );
}

function Addresses({ domains, setMessage, selectedAddress, onSelectAddress }) {
  const api = useApi();
  const [addresses, setAddresses] = useState([]);
  const [query, setQuery] = useState('');
  const [showRequest, setShowRequest] = useState(false);
  const [pendingRevoke, setPendingRevoke] = useState(null);
  const [pendingScroll, setPendingScroll] = useState(null);
  const listRef = useRef(null);

  const refresh = useCallback(() => {
    api.getAddresses().then((data) => {
      try {
        localStorage.setItem(ADDRESS_LIST, JSON.stringify(data));
      } catch (e) {
        console.log(e);
      }
      setAddresses(sortAddresses(data.data.Items));
    }).catch((e) => {
      console.log(e);
    });
  }, [api]);

  useEffect(() => { refresh(); }, [refresh]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return addresses;
    return addresses.filter((a) =>
      [a.address, a.comment].filter(Boolean).join('.').toLowerCase().includes(q)
    );
  }, [addresses, query]);

  const hiddenCount = addresses.length - filtered.length;
  const favoriteItems = useMemo(() => filtered.filter((a) => a.favorite), [filtered]);
  const showSections = favoriteItems.length > 0;

  const handleSelect = useCallback((address) => {
    if (typeof onSelectAddress !== 'function') return;
    onSelectAddress(selectedAddress === address ? null : address);
  }, [onSelectAddress, selectedAddress]);

  const openRequest = useCallback((e) => {
    if (e) e.stopPropagation();
    setShowRequest(true);
  }, []);

  const closeRequest = useCallback(() => {
    setShowRequest(false);
  }, []);

  const onRequested = useCallback((newAddress) => {
    setShowRequest(false);
    localStorage.removeItem(ADDRESS_LIST);
    refresh();
    setPendingScroll(newAddress);
    if (typeof onSelectAddress === 'function') onSelectAddress(newAddress);
  }, [refresh, onSelectAddress]);

  // After a successful new-address request, scroll the new row into view
  // once the refreshed list lands in state. block:'nearest' means we only
  // scroll if the row isn't already visible.
  useEffect(() => {
    if (!pendingScroll) return;
    if (!addresses.some((a) => a.address === pendingScroll)) return;
    const container = listRef.current;
    if (!container) { setPendingScroll(null); return; }
    const row = container.querySelector(`[data-address="${CSS.escape(pendingScroll)}"]`);
    if (row && typeof row.scrollIntoView === 'function') {
      row.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
    setPendingScroll(null);
  }, [addresses, pendingScroll]);

  const copyAddress = useCallback((e, a) => {
    e.stopPropagation();
    const done = (ok) => {
      if (!setMessage) return;
      if (ok) setMessage('Address copied to clipboard.', false);
      else setMessage('Failed to copy address.', true);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(a.address).then(() => done(true), () => done(false));
    } else {
      done(false);
    }
  }, [setMessage]);

  const requestRevoke = useCallback((e, a) => {
    e.stopPropagation();
    setPendingRevoke(a);
  }, []);

  const cancelRevoke = useCallback(() => {
    setPendingRevoke(null);
  }, []);

  const toggleFavorite = useCallback((e, a) => {
    e.stopPropagation();
    const next = !a.favorite;
    // Optimistic update; revert and notify on failure.
    setAddresses((prev) => prev.map((x) => (
      x.address === a.address ? { ...x, favorite: next } : x
    )));
    api.setFavorite(a.address, next).catch(() => {
      setAddresses((prev) => prev.map((x) => (
        x.address === a.address ? { ...x, favorite: a.favorite } : x
      )));
      setMessage && setMessage('Could not update favorite.', true);
    });
  }, [api, setMessage]);

  const confirmRevoke = useCallback(() => {
    const a = pendingRevoke;
    if (!a) return;
    setPendingRevoke(null);
    api.deleteAddress(a.address, a.subdomain, a.tld, a.public_key).then(() => {
      setMessage && setMessage('Successfully revoked address.', false);
      localStorage.removeItem(ADDRESS_LIST);
      setAddresses((prev) => prev.filter((x) => x.address !== a.address));
      if (selectedAddress === a.address && typeof onSelectAddress === 'function') {
        onSelectAddress(null);
      }
    }).catch(() => {
      setMessage && setMessage('Request to revoke address failed.', true);
    });
  }, [api, pendingRevoke, setMessage, selectedAddress, onSelectAddress]);

  return (
    <section className="addresses-rail" aria-label="Addresses">
      <div className="addresses-rail__header" role="button" tabIndex={0}>
        <span className="addresses-rail__label">Addresses</span>
        <span className="addresses-rail__actions">
          <button
            type="button"
            className="addresses-rail__action"
            title="New address"
            aria-label="New address"
            onClick={openRequest}
          >
            <Plus size={14} aria-hidden="true" />
          </button>
        </span>
      </div>

      <div className="addresses-rail__search">
        <Search className="addresses-rail__search-icon" size={13} aria-hidden="true" />
        <input
          type="search"
          className="addresses-rail__search-input"
          placeholder="Filter addresses…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Filter addresses"
        />
        {query && (
          <button
            type="button"
            className="addresses-rail__search-clear"
            title="Clear"
            aria-label="Clear filter"
            onClick={() => setQuery('')}
          >
            <X size={11} aria-hidden="true" />
          </button>
        )}
      </div>

      <ul className="addresses-rail__list" ref={listRef}>
        {filtered.length === 0 && query && (
          <li className="addresses-rail__empty">No matches</li>
        )}

        {showSections && (
          <li className="addresses-rail__section-label" aria-hidden="true">Favorites</li>
        )}
        {showSections && favoriteItems.map((a) => (
          <AddressRow
            key={`fav-${a.address}`}
            a={a}
            isActive={selectedAddress === a.address}
            isFavorite
            onSelect={handleSelect}
            onToggleFavorite={toggleFavorite}
            onCopy={copyAddress}
            onRevoke={requestRevoke}
          />
        ))}

        {showSections && filtered.length > 0 && (
          <li className="addresses-rail__section-label" aria-hidden="true">All addresses</li>
        )}
        {filtered.map((a) => (
          <AddressRow
            key={a.address}
            a={a}
            isActive={selectedAddress === a.address}
            isFavorite={!!a.favorite}
            onSelect={handleSelect}
            onToggleFavorite={toggleFavorite}
            onCopy={copyAddress}
            onRevoke={requestRevoke}
          />
        ))}

        {!query && (
          <li
            className="addresses-rail__row addresses-rail__row--new"
            onClick={openRequest}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => { if (e.key === 'Enter') openRequest(); }}
          >
            <span className="addresses-rail__new-label">+ New address…</span>
          </li>
        )}

        {!query && hiddenCount === 0 && addresses.length > 5 && (
          <li className="addresses-rail__hint">
            Type to search {addresses.length} addresses
          </li>
        )}
      </ul>

      {showRequest && (
        <div className="addresses-rail__modal-scrim" onClick={closeRequest}>
          <div className="addresses-rail__modal" onClick={(e) => e.stopPropagation()}>
            <div className="addresses-rail__modal-head">
              <span>New address</span>
              <button
                type="button"
                className="addresses-rail__modal-close"
                aria-label="Close"
                onClick={closeRequest}
              >
                <X size={14} aria-hidden="true" />
              </button>
            </div>
            <Request
              domains={domains}
              setMessage={setMessage}
              callback={onRequested}
            />
          </div>
        </div>
      )}

      <ConfirmDialog
        open={pendingRevoke !== null}
        title="Revoke address?"
        message={pendingRevoke ? (
          <>
            Mail sent to <strong>{pendingRevoke.address}</strong> will be rejected.
            {' '}This can&rsquo;t be undone.
          </>
        ) : null}
        confirmLabel="Revoke"
        cancelLabel="Cancel"
        destructive
        onConfirm={confirmRevoke}
        onCancel={cancelRevoke}
      />
    </section>
  );
}

export default Addresses;
