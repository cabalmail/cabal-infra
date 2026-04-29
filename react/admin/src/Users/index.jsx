import { useState, useEffect, useCallback, useMemo } from 'react';
import useApi from '../hooks/useApi';
import { useAppMessage } from '../contexts/AppMessageContext';
import ConfirmDialog from '../ConfirmDialog';
import './Users.css';

function Users() {
  const api = useApi();
  const { setMessage } = useAppMessage();
  const [users, setUsers] = useState([]);
  const [addresses, setAddresses] = useState([]);
  const [loading, setLoading] = useState(true);
  const [pickerFor, setPickerFor] = useState(null);
  const [pickerAddress, setPickerAddress] = useState('');
  const [hoveredAddr, setHoveredAddr] = useState(null);
  const [stickyAddr, setStickyAddr] = useState(null);
  const [pendingDelete, setPendingDelete] = useState(null);
  const [pendingUnassign, setPendingUnassign] = useState(null);
  const highlighted = hoveredAddr || stickyAddr;

  const loadUsers = useCallback(() => {
    setLoading(true);
    Promise.all([
      api.listUsers(),
      api.listAllAddresses().catch(() => ({ data: { Items: [] } }))
    ]).then(
      ([userResp, addrResp]) => {
        const userData = userResp.data || userResp;
        const addrData = addrResp.data || addrResp;
        setUsers(userData.Users || []);
        setAddresses(addrData.Items || []);
        setLoading(false);
      },
      (err) => {
        setMessage("Failed to load users: " + (err.message || err), true);
        setLoading(false);
      }
    );
  }, [api, setMessage]);

  useEffect(() => {
    loadUsers();
  }, [loadUsers]);

  const addressesByUser = useMemo(() => {
    const map = {};
    addresses.forEach(a => {
      const assigned = (a.user || '').split('/').filter(Boolean);
      assigned.forEach(u => {
        if (!map[u]) map[u] = [];
        map[u].push(a);
      });
    });
    return map;
  }, [addresses]);

  const handleConfirm = useCallback((username) => {
    api.confirmUser(username).then(
      () => {
        setMessage(`User "${username}" confirmed.`, false);
        loadUsers();
      },
      (err) => {
        setMessage("Failed to confirm user: " + (err.message || err), true);
      }
    );
  }, [api, setMessage, loadUsers]);

  const handleDisable = useCallback((username) => {
    api.disableUser(username).then(
      () => {
        setMessage(`User "${username}" disabled.`, false);
        loadUsers();
      },
      (err) => {
        setMessage("Failed to disable user: " + (err.message || err), true);
      }
    );
  }, [api, setMessage, loadUsers]);

  const handleEnable = useCallback((username) => {
    api.enableUser(username).then(
      () => {
        setMessage(`User "${username}" enabled.`, false);
        loadUsers();
      },
      (err) => {
        setMessage("Failed to enable user: " + (err.message || err), true);
      }
    );
  }, [api, setMessage, loadUsers]);

  const handleDelete = useCallback((username) => {
    setPendingDelete(username);
  }, []);

  const cancelDelete = useCallback(() => {
    setPendingDelete(null);
  }, []);

  const confirmDelete = useCallback(() => {
    const username = pendingDelete;
    if (!username) return;
    setPendingDelete(null);
    api.deleteUser(username).then(
      () => {
        setMessage(`User "${username}" deleted.`, false);
        loadUsers();
      },
      (err) => {
        setMessage("Failed to delete user: " + (err.message || err), true);
      }
    );
  }, [api, pendingDelete, setMessage, loadUsers]);

  const handleAssign = useCallback((username, address) => {
    if (!address) {
      setMessage('Select an address to assign.', true);
      return;
    }
    api.assignAddress(address, username).then(
      () => {
        setMessage(`Assigned "${username}" to "${address}".`, false);
        setPickerFor(null);
        setPickerAddress('');
        loadUsers();
      },
      (err) => {
        const msg = err.response?.data?.Error || err.message || err;
        setMessage('Failed to assign address: ' + msg, true);
      }
    );
  }, [api, setMessage, loadUsers]);

  const handleUnassign = useCallback((username, address) => {
    setPendingUnassign({ username, address });
  }, []);

  const cancelUnassign = useCallback(() => {
    setPendingUnassign(null);
  }, []);

  const confirmUnassign = useCallback(() => {
    const target = pendingUnassign;
    if (!target) return;
    setPendingUnassign(null);
    const { username, address } = target;
    api.unassignAddress(address, username).then(
      () => {
        setMessage(`Removed "${username}" from "${address}".`, false);
        loadUsers();
      },
      (err) => {
        const msg = err.response?.data?.Error || err.message || err;
        setMessage('Failed to remove assignment: ' + msg, true);
      }
    );
  }, [api, pendingUnassign, setMessage, loadUsers]);

  const nonSystemUsers = users.filter(u => !['master', 'dmarc'].includes(u.username));
  const pendingUsers = nonSystemUsers.filter(u => u.status !== 'CONFIRMED');
  const confirmedUsers = nonSystemUsers.filter(u => u.status === 'CONFIRMED');

  if (loading) {
    return <div className="Users"><div className="loading">Loading...</div></div>;
  }

  return (
    <div className="Users">
      <button id="reload" onClick={loadUsers}>&#x21bb;</button>

      <ConfirmDialog
        open={pendingDelete !== null}
        title="Delete user?"
        message={pendingDelete ? (
          <>
            User <strong>{pendingDelete}</strong> will be permanently deleted.
            {' '}This can&rsquo;t be undone.
          </>
        ) : null}
        confirmLabel="Delete"
        cancelLabel="Cancel"
        destructive
        onConfirm={confirmDelete}
        onCancel={cancelDelete}
      />

      <ConfirmDialog
        open={pendingUnassign !== null}
        title="Remove user from address?"
        message={pendingUnassign ? (
          <>
            Remove <strong>{pendingUnassign.username}</strong> from{' '}
            <strong>{pendingUnassign.address}</strong>?
          </>
        ) : null}
        confirmLabel="Remove"
        cancelLabel="Cancel"
        destructive
        onConfirm={confirmUnassign}
        onCancel={cancelUnassign}
      />

      <h2>Pending Users</h2>
      {pendingUsers.length === 0 ? (
        <p className="empty">No pending users.</p>
      ) : (
        <ul className="user-list">
          {pendingUsers.map(user => (
            <li key={user.username} className="user-row">
              <span className="username">{user.username}</span>
              <span className="status">{user.status}</span>
              <span className="created">{new Date(user.created).toLocaleDateString()}</span>
              <button className="action confirm" onClick={() => handleConfirm(user.username)}>Confirm</button>
              <button className="action delete" onClick={() => handleDelete(user.username)}>Delete</button>
            </li>
          ))}
        </ul>
      )}

      <h2>Confirmed Users</h2>
      {confirmedUsers.length === 0 ? (
        <p className="empty">No confirmed users.</p>
      ) : (
        <ul className="user-list">
          {confirmedUsers.map(user => {
            const userAddrs = addressesByUser[user.username] || [];
            const assignedSet = new Set(userAddrs.map(a => a.address));
            const remaining = addresses.filter(a => !assignedSet.has(a.address));
            return (
              <li key={user.username} className="user-row-extended">
                <div className="user-row">
                  <span className="username">{user.username}</span>
                  <span className="enabled">{user.enabled ? 'Enabled' : 'Disabled'}</span>
                  <span className="osid">{user.osid ? `OSID: ${user.osid}` : ''}</span>
                  <span className="created">{new Date(user.created).toLocaleDateString()}</span>
                  {user.enabled ? (
                    <button className="action disable" onClick={() => handleDisable(user.username)}>Disable</button>
                  ) : (
                    <button className="action enable" onClick={() => handleEnable(user.username)}>Enable</button>
                  )}
                  <button className="action delete" onClick={() => handleDelete(user.username)}>Delete</button>
                </div>
                <div className="user-addresses">
                  <span className="addresses-label">Addresses:</span>
                  {userAddrs.length === 0 && <span className="none">none</span>}
                  {userAddrs.map(a => {
                    const sharers = (a.user || '').split('/').filter(Boolean);
                    const canRemove = sharers.length > 1;
                    const isShared = sharers.length > 1;
                    const classes = [
                      'address-chip',
                      isShared ? 'shared' : '',
                      highlighted === a.address ? 'highlighted' : ''
                    ].filter(Boolean).join(' ');
                    return (
                      <span
                        key={a.address}
                        className={classes}
                        onMouseEnter={isShared ? () => setHoveredAddr(a.address) : undefined}
                        onMouseLeave={isShared ? () => setHoveredAddr(prev => prev === a.address ? null : prev) : undefined}
                        onClick={isShared ? () => setStickyAddr(prev => prev === a.address ? null : a.address) : undefined}
                      >
                        {a.address}
                        {canRemove && (
                          <button
                            className="chip-remove"
                            onClick={() => handleUnassign(user.username, a.address)}
                            title={`Remove ${user.username} from ${a.address}`}
                          >&times;</button>
                        )}
                      </span>
                    );
                  })}
                  {pickerFor === user.username ? (
                    <span className="user-picker-inline">
                      <select
                        value={pickerAddress}
                        onChange={(e) => setPickerAddress(e.target.value)}
                      >
                        <option value="">Select address…</option>
                        {remaining.map(a => (
                          <option key={a.address} value={a.address}>{a.address}</option>
                        ))}
                      </select>
                      <button onClick={() => handleAssign(user.username, pickerAddress)}>Add</button>
                      <button onClick={() => { setPickerFor(null); setPickerAddress(''); }}>Cancel</button>
                    </span>
                  ) : (
                    remaining.length > 0 && (
                      <button
                        className="add-address"
                        onClick={() => { setPickerFor(user.username); setPickerAddress(''); }}
                      >+ Address</button>
                    )
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

export default Users;
