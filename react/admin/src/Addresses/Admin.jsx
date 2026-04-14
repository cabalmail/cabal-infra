import React, { useState, useEffect, useCallback, useMemo } from 'react';
import useApi from '../hooks/useApi';

function Admin({ domains, setMessage }) {
  const api = useApi();
  const [addresses, setAddresses] = useState([]);
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState('');
  const [showNew, setShowNew] = useState(false);

  // New-address form state
  const [username, setUsername] = useState('');
  const [subdomain, setSubdomain] = useState('');
  const [domain, setDomain] = useState('');
  const [comment, setComment] = useState('');
  const [selectedUsers, setSelectedUsers] = useState([]);

  // Per-row "add user" picker state
  const [pickerFor, setPickerFor] = useState(null);
  const [pickerUser, setPickerUser] = useState('');

  const newAddress = useMemo(() => {
    if (username && subdomain && domain) {
      return `${username}@${subdomain}.${domain}`;
    }
    return '';
  }, [username, subdomain, domain]);

  const loadData = useCallback(() => {
    setLoading(true);
    Promise.all([
      api.listAllAddresses(),
      api.listUsers()
    ]).then(
      ([addrResp, userResp]) => {
        const addrData = addrResp.data || addrResp;
        const userData = userResp.data || userResp;
        setAddresses(addrData.Items || []);
        setUsers(userData.Users || []);
        setLoading(false);
      },
      (err) => {
        setMessage('Failed to load admin data: ' + (err.message || err), true);
        setLoading(false);
      }
    );
  }, [api, setMessage]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  const usernameOptions = useMemo(() => {
    return users
      .filter(u => u.status === 'CONFIRMED' && u.enabled)
      .filter(u => !['master', 'dmarc'].includes(u.username))
      .map(u => u.username)
      .sort();
  }, [users]);

  const filteredAddresses = useMemo(() => {
    const f = filter.toLowerCase();
    const filtered = addresses.filter(a => {
      const haystack = [a.address, a.comment || '', a.user || ''].join(' ').toLowerCase();
      return haystack.includes(f);
    });
    return filtered.slice().sort((a, b) => a.address.localeCompare(b.address));
  }, [addresses, filter]);

  const handleAssign = useCallback((address, user) => {
    if (!user) {
      setMessage('Select a user to assign.', true);
      return;
    }
    api.assignAddress(address, user).then(
      () => {
        setMessage(`Assigned "${user}" to "${address}".`, false);
        setPickerFor(null);
        setPickerUser('');
        loadData();
      },
      (err) => {
        const msg = err.response?.data?.Error || err.message || err;
        setMessage('Failed to assign user: ' + msg, true);
      }
    );
  }, [api, setMessage, loadData]);

  const handleUnassign = useCallback((address, user) => {
    if (!window.confirm(`Remove "${user}" from "${address}"?`)) return;
    api.unassignAddress(address, user).then(
      () => {
        setMessage(`Removed "${user}" from "${address}".`, false);
        loadData();
      },
      (err) => {
        const msg = err.response?.data?.Error || err.message || err;
        setMessage('Failed to remove user: ' + msg, true);
      }
    );
  }, [api, setMessage, loadData]);

  const toggleSelectedUser = useCallback((u) => {
    setSelectedUsers(prev =>
      prev.includes(u) ? prev.filter(x => x !== u) : [...prev, u]
    );
  }, []);

  const handleCreate = useCallback((e) => {
    e.preventDefault();
    if (!username || !subdomain || !domain) {
      setMessage('Provide username, subdomain, and domain.', true);
      return;
    }
    if (selectedUsers.length === 0) {
      setMessage('Select at least one user to assign.', true);
      return;
    }
    api.newAddressAdmin(username, subdomain, domain, comment, newAddress, selectedUsers).then(
      (resp) => {
        const data = resp.data || resp;
        setMessage(`Created "${data.address}" assigned to ${data.user}.`, false);
        setUsername(''); setSubdomain(''); setDomain(''); setComment('');
        setSelectedUsers([]);
        setShowNew(false);
        loadData();
      },
      (err) => {
        const msg = err.response?.data?.error || err.response?.data?.Error || err.message || err;
        setMessage('Failed to create address: ' + msg, true);
      }
    );
  }, [api, username, subdomain, domain, comment, newAddress, selectedUsers, setMessage, loadData]);

  if (loading) {
    return <div className="loading">Loading admin view...</div>;
  }

  return (
    <div className="admin-addresses">
      <button
        onClick={() => setShowNew(prev => !prev)}
        className="toggleRequest"
      >New Address {showNew ? '▼' : '▶︎'}</button>

      <div className={`admin-new-wrapper ${showNew ? 'visible' : 'hidden'}`}>
        <fieldset className="address-fields">
          <legend>Address</legend>
          <input
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            placeholder="username"
            autoComplete="off"
            autoCorrect="off"
            autoCapitalize="none"
          /><span id="amphora">@</span><input
            type="text"
            value={subdomain}
            onChange={(e) => setSubdomain(e.target.value)}
            placeholder="subdomain"
            autoComplete="off"
            autoCorrect="off"
            autoCapitalize="none"
          /><span id="dot">.</span><select
            value={domain}
            onChange={(e) => setDomain(e.target.value)}
          >
            <option value="">Select a domain</option>
            {domains.map(d => (
              <option key={d.domain} value={d.domain}>{d.domain}</option>
            ))}
          </select>
        </fieldset>
        <fieldset className="comment-field">
          <legend>Comment</legend>
          <input
            type="text"
            value={comment}
            onChange={(e) => setComment(e.target.value)}
            placeholder="comment"
            autoComplete="off"
            autoCorrect="off"
            autoCapitalize="none"
          />
        </fieldset>
        <fieldset className="assign-field">
          <legend>Assign to</legend>
          <div className="assign-checkboxes">
            {usernameOptions.map(u => (
              <label key={u} className="user-checkbox">
                <input
                  type="checkbox"
                  checked={selectedUsers.includes(u)}
                  onChange={() => toggleSelectedUser(u)}
                />
                <span>{u}</span>
              </label>
            ))}
          </div>
        </fieldset>
        <fieldset className="button-fields">
          <button id="create-admin" className="default" onClick={handleCreate}>
            Create {newAddress}
          </button>
        </fieldset>
      </div>

      <hr />

      <div className="admin-controls">
        <input
          type="text"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          id="filter"
          name="filter"
          placeholder="filter"
        />
        <button id="reload" onClick={loadData} title="Reload">&#10227;</button>
      </div>

      <div id="count">Found: {filteredAddresses.length} addresses</div>

      <ul className="admin-address-list">
        {filteredAddresses.map(a => {
          const assignedUsers = (a.user || '').split('/').filter(Boolean);
          const remaining = usernameOptions.filter(u => !assignedUsers.includes(u));
          return (
            <li key={a.address} className="admin-address-row">
              <div className="admin-address-main">
                <span className="address">{a.address.replace(/([.@])/g, '$&\u200B')}</span>
                <span className="comment">{a.comment}</span>
              </div>
              <div className="admin-address-users">
                {assignedUsers.map(u => (
                  <span key={u} className="user-chip">
                    {u}
                    {assignedUsers.length > 1 && (
                      <button
                        className="chip-remove"
                        onClick={() => handleUnassign(a.address, u)}
                        title={`Remove ${u}`}
                      >&times;</button>
                    )}
                  </span>
                ))}
                {pickerFor === a.address ? (
                  <span className="user-picker-inline">
                    <select
                      value={pickerUser}
                      onChange={(e) => setPickerUser(e.target.value)}
                    >
                      <option value="">Select user…</option>
                      {remaining.map(u => (
                        <option key={u} value={u}>{u}</option>
                      ))}
                    </select>
                    <button onClick={() => handleAssign(a.address, pickerUser)}>Add</button>
                    <button onClick={() => { setPickerFor(null); setPickerUser(''); }}>Cancel</button>
                  </span>
                ) : (
                  remaining.length > 0 && (
                    <button
                      className="add-user"
                      onClick={() => { setPickerFor(a.address); setPickerUser(''); }}
                    >+ User</button>
                  )
                )}
              </div>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

export default Admin;
