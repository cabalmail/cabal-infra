import { useState, useEffect, useCallback } from 'react';
import useApi from '../hooks/useApi';
import { useAppMessage } from '../contexts/AppMessageContext';
import './Users.css';

function Users() {
  const api = useApi();
  const { setMessage } = useAppMessage();
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(true);

  const loadUsers = useCallback(() => {
    setLoading(true);
    api.listUsers().then(
      (response) => {
        const data = response.data || response;
        setUsers(data.Users || []);
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
    if (!window.confirm(`Delete user "${username}"? This cannot be undone.`)) {
      return;
    }
    api.deleteUser(username).then(
      () => {
        setMessage(`User "${username}" deleted.`, false);
        loadUsers();
      },
      (err) => {
        setMessage("Failed to delete user: " + (err.message || err), true);
      }
    );
  }, [api, setMessage, loadUsers]);

  const nonMasterUsers = users.filter(u => u.username !== 'master');
  const pendingUsers = nonMasterUsers.filter(u => u.status !== 'CONFIRMED');
  const confirmedUsers = nonMasterUsers.filter(u => u.status === 'CONFIRMED');

  if (loading) {
    return <div className="Users"><div className="loading">Loading...</div></div>;
  }

  return (
    <div className="Users">
      <button id="reload" onClick={loadUsers}>&#x21bb;</button>

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
          {confirmedUsers.map(user => (
            <li key={user.username} className="user-row">
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
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export default Users;
