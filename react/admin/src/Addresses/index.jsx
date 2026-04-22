import { useCallback, useEffect, useMemo, useState } from 'react';
import useApi from '../hooks/useApi';
import { ADDRESS_LIST } from '../constants';
import Request from './Request';
import './Admin.css';

function AdminAddresses({ domains, setMessage }) {
  const api = useApi();
  const [addresses, setAddresses] = useState([]);
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState('');
  const [showNew, setShowNew] = useState(false);
  const [pickerFor, setPickerFor] = useState(null);
  const [pickerUser, setPickerUser] = useState('');

  const loadData = useCallback(() => {
    setLoading(true);
    Promise.all([
      api.listAllAddresses(),
      api.listUsers().catch(() => ({ data: { Users: [] } })),
    ]).then(
      ([addrResp, userResp]) => {
        const addrData = addrResp.data || addrResp;
        const userData = userResp.data || userResp;
        setAddresses(addrData.Items || []);
        setUsers(userData.Users || []);
        setLoading(false);
      },
      (err) => {
        setMessage && setMessage('Failed to load addresses: ' + (err.message || err), true);
        setLoading(false);
      }
    );
  }, [api, setMessage]);

  useEffect(() => { loadData(); }, [loadData]);

  const usernameOptions = useMemo(() => (
    users
      .filter((u) => u.status === 'CONFIRMED' && u.enabled)
      .filter((u) => !['master', 'dmarc'].includes(u.username))
      .map((u) => u.username)
      .sort()
  ), [users]);

  const filteredAddresses = useMemo(() => {
    const f = filter.trim().toLowerCase();
    const list = f
      ? addresses.filter((a) => (
          [a.address, a.comment || '', a.user || ''].join(' ').toLowerCase().includes(f)
        ))
      : addresses;
    return list.slice().sort((a, b) => a.address.localeCompare(b.address));
  }, [addresses, filter]);

  const handleRequested = useCallback((newAddress) => {
    localStorage.removeItem(ADDRESS_LIST);
    setShowNew(false);
    if (newAddress) {
      setMessage && setMessage(`Address "${newAddress}" created.`, false);
    }
    loadData();
  }, [setMessage, loadData]);

  const handleAssign = useCallback((address, username) => {
    if (!username) {
      setMessage && setMessage('Select a user to assign.', true);
      return;
    }
    api.assignAddress(address, username).then(
      () => {
        setMessage && setMessage(`Assigned "${username}" to "${address}".`, false);
        setPickerFor(null);
        setPickerUser('');
        loadData();
      },
      (err) => {
        const msg = err.response?.data?.Error || err.message || err;
        setMessage && setMessage('Failed to assign user: ' + msg, true);
      }
    );
  }, [api, setMessage, loadData]);

  const handleUnassign = useCallback((address, username) => {
    if (!window.confirm(`Remove "${username}" from "${address}"?`)) return;
    api.unassignAddress(address, username).then(
      () => {
        setMessage && setMessage(`Removed "${username}" from "${address}".`, false);
        loadData();
      },
      (err) => {
        const msg = err.response?.data?.Error || err.message || err;
        setMessage && setMessage('Failed to remove user: ' + msg, true);
      }
    );
  }, [api, setMessage, loadData]);

  const handleRevoke = useCallback((a) => {
    if (!window.confirm(`Revoke "${a.address}"? This cannot be undone.`)) return;
    api.deleteAddress(a.address, a.subdomain, a.tld, a.public_key).then(
      () => {
        setMessage && setMessage(`Revoked "${a.address}".`, false);
        localStorage.removeItem(ADDRESS_LIST);
        loadData();
      },
      (err) => {
        const msg = err.response?.data?.Error || err.message || err;
        setMessage && setMessage('Failed to revoke address: ' + msg, true);
      }
    );
  }, [api, setMessage, loadData]);

  if (loading) {
    return <div className="admin-addresses"><div className="loading">Loading addresses…</div></div>;
  }

  return (
    <div className="admin-addresses">
      <div className="admin-addresses__header">
        <h2>All Addresses</h2>
        <button
          type="button"
          className="admin-addresses__reload"
          title="Reload"
          onClick={loadData}
        >&#10227;</button>
      </div>

      <button
        type="button"
        onClick={() => setShowNew((prev) => !prev)}
        className="admin-addresses__new-toggle"
      >New Address {showNew ? '▼' : '▶︎'}</button>

      {showNew && (
        <div className="admin-addresses__new">
          <Request
            domains={domains}
            showRequest={true}
            setMessage={setMessage}
            callback={handleRequested}
          />
        </div>
      )}

      <div className="admin-addresses__controls">
        <input
          type="text"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          placeholder="Filter by address, comment, or user…"
          className="admin-addresses__filter"
        />
        <span className="admin-addresses__count">
          {filteredAddresses.length} of {addresses.length}
        </span>
      </div>

      {filteredAddresses.length === 0 ? (
        <p className="admin-addresses__empty">
          {filter ? 'No addresses match the filter.' : 'No addresses yet.'}
        </p>
      ) : (
        <ul className="admin-addresses__list">
          {filteredAddresses.map((a) => {
            const assignedUsers = (a.user || '').split('/').filter(Boolean);
            const remaining = usernameOptions.filter((u) => !assignedUsers.includes(u));
            return (
              <li key={a.address} className="admin-addresses__row">
                <div className="admin-addresses__main">
                  <span className="admin-addresses__address">
                    {a.address.replace(/([.@])/g, '$&\u200B')}
                  </span>
                  {a.comment && (
                    <span className="admin-addresses__comment">{a.comment}</span>
                  )}
                </div>
                <div className="admin-addresses__users">
                  {assignedUsers.length === 0 && (
                    <span className="admin-addresses__none">unassigned</span>
                  )}
                  {assignedUsers.map((u) => (
                    <span key={u} className="admin-addresses__chip">
                      {u}
                      {assignedUsers.length > 1 && (
                        <button
                          type="button"
                          className="admin-addresses__chip-remove"
                          title={`Remove ${u}`}
                          aria-label={`Remove ${u} from ${a.address}`}
                          onClick={() => handleUnassign(a.address, u)}
                        >&times;</button>
                      )}
                    </span>
                  ))}
                  {pickerFor === a.address ? (
                    <span className="admin-addresses__picker">
                      <select
                        value={pickerUser}
                        onChange={(e) => setPickerUser(e.target.value)}
                      >
                        <option value="">Select user…</option>
                        {remaining.map((u) => (
                          <option key={u} value={u}>{u}</option>
                        ))}
                      </select>
                      <button
                        type="button"
                        onClick={() => handleAssign(a.address, pickerUser)}
                      >Add</button>
                      <button
                        type="button"
                        onClick={() => { setPickerFor(null); setPickerUser(''); }}
                      >Cancel</button>
                    </span>
                  ) : (
                    remaining.length > 0 && (
                      <button
                        type="button"
                        className="admin-addresses__add-user"
                        onClick={() => { setPickerFor(a.address); setPickerUser(''); }}
                      >+ User</button>
                    )
                  )}
                </div>
                <button
                  type="button"
                  className="admin-addresses__revoke"
                  title={`Revoke ${a.address}`}
                  aria-label={`Revoke ${a.address}`}
                  onClick={() => handleRevoke(a)}
                >Revoke</button>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

export default AdminAddresses;
