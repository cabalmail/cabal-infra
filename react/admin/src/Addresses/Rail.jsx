import { useCallback, useEffect, useMemo, useState } from 'react';
import { Plus, Search, X } from 'lucide-react';
import useApi from '../hooks/useApi';
import { ADDRESS_LIST } from '../constants';
import { swatchFor } from '../utils/addressSwatch';
import Request from './Request';
import './Addresses.css';

function sortAddresses(items) {
  return items.slice().sort((a, b) => {
    if (a.address > b.address) return 1;
    if (a.address < b.address) return -1;
    return 0;
  });
}

function Addresses({ domains, setMessage, selectedAddress, onSelectAddress }) {
  const api = useApi();
  const [addresses, setAddresses] = useState([]);
  const [query, setQuery] = useState('');
  const [showRequest, setShowRequest] = useState(false);

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

  const handleSelect = useCallback((address) => {
    if (typeof onSelectAddress === 'function') onSelectAddress(address);
  }, [onSelectAddress]);

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
    if (typeof onSelectAddress === 'function') onSelectAddress(newAddress);
  }, [refresh, onSelectAddress]);

  const revoke = useCallback((e, a) => {
    e.stopPropagation();
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
  }, [api, setMessage, selectedAddress, onSelectAddress]);

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

      <ul className="addresses-rail__list">
        {filtered.length === 0 && query && (
          <li className="addresses-rail__empty">No matches</li>
        )}
        {filtered.map((a) => {
          const isActive = selectedAddress === a.address;
          return (
            <li
              key={a.address}
              id={a.address}
              className={`addresses-rail__row${isActive ? ' is-active' : ''}`}
              title={a.comment || a.address}
              onClick={() => handleSelect(a.address)}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => { if (e.key === 'Enter') handleSelect(a.address); }}
              aria-current={isActive ? 'true' : undefined}
            >
              <span
                className="addresses-rail__swatch"
                style={{ background: swatchFor(a.address) }}
                aria-hidden="true"
              />
              <span className="addresses-rail__address">{a.address}</span>
              <span className="addresses-rail__row-actions" onClick={(e) => e.stopPropagation()}>
                <button
                  type="button"
                  className="addresses-rail__row-action"
                  title="Revoke address"
                  aria-label={`Revoke ${a.address}`}
                  onClick={(e) => revoke(e, a)}
                >
                  <X size={12} aria-hidden="true" />
                </button>
              </span>
            </li>
          );
        })}

        {!query && (
          <li
            className="addresses-rail__row addresses-rail__row--new"
            onClick={openRequest}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => { if (e.key === 'Enter') openRequest(); }}
          >
            <span className="addresses-rail__swatch addresses-rail__swatch--ghost" aria-hidden="true" />
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
              showRequest={true}
              setMessage={setMessage}
              callback={onRequested}
            />
          </div>
        </div>
      )}
    </section>
  );
}

export default Addresses;
