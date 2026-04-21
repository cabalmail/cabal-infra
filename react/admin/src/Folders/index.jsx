import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Archive,
  ChevronDown,
  FileText,
  Folder,
  Inbox,
  Pencil,
  Plus,
  Send,
  ShieldAlert,
  Star,
  Trash2,
  X,
} from 'lucide-react';
import useApi from '../hooks/useApi';
import { FOLDER_LIST, PERMANENT_FOLDERS } from '../constants';
import { orderFolders } from '../utils/folderMeta';
import styles from './Folders.module.css';

const KIND_ICON = {
  inbox:   Inbox,
  drafts:  FileText,
  sent:    Send,
  archive: Archive,
  trash:   Trash2,
  junk:    ShieldAlert,
  folder:  Folder,
};

function FolderIcon({ kind }) {
  const Icon = KIND_ICON[kind] || Folder;
  return <Icon className={styles.folderIcon} size={16} aria-hidden="true" />;
}

function Folders({ setMessage, folder, setFolder, onNewMessage, asDrawer = false, onClose }) {
  const api = useApi();
  const [folders, setFolders] = useState([]);
  const [subscribed, setSubscribed] = useState([]);
  const [collapsed, setCollapsed] = useState(false);
  const [adding, setAdding] = useState(false);
  const [newName, setNewName] = useState('');

  const refresh = useCallback(() => {
    api.getFolderList().then(data => {
      try {
        localStorage.setItem(FOLDER_LIST, JSON.stringify(data));
      } catch (e) {
        console.log(e);
      }
      const all = [...new Set([
        ...(data.data.folders),
        ...(data.data.sub_folders),
      ])];
      setFolders(all);
      setSubscribed(data.data.sub_folders);
    }).catch(e => {
      console.log(e);
    });
  }, [api]);

  useEffect(() => { refresh(); }, [refresh]);

  const items = useMemo(() => orderFolders(folders), [folders]);

  const handleSelect = useCallback((name) => {
    if (typeof setFolder === 'function') setFolder(name);
  }, [setFolder]);

  const toggleSubscribe = useCallback((e, name) => {
    e.stopPropagation();
    const p = subscribed.includes(name)
      ? api.unsubscribeFolder(name)
      : api.subscribeFolder(name);
    p.then(() => {
      localStorage.removeItem(FOLDER_LIST);
      refresh();
    });
  }, [api, subscribed, refresh]);

  const removeFolder = useCallback((e, name) => {
    e.stopPropagation();
    api.deleteFolder(name).then(() => {
      localStorage.removeItem(FOLDER_LIST);
      refresh();
    }).catch(() => {
      setMessage && setMessage('Unable to delete folder.', true);
    });
  }, [api, refresh, setMessage]);

  const commitAdd = useCallback(() => {
    const name = newName.trim();
    if (!name) { setAdding(false); return; }
    if (name.includes('.') || name.includes('/')) {
      setMessage && setMessage("Folder names must not contain '.' or '/'.", true);
      return;
    }
    api.newFolder('', name).then(() => {
      setAdding(false);
      setNewName('');
      localStorage.removeItem(FOLDER_LIST);
      refresh();
    }).catch(() => {
      setMessage && setMessage('Unable to create folder.', true);
    });
  }, [api, newName, refresh, setMessage]);

  const cancelAdd = useCallback(() => {
    setAdding(false);
    setNewName('');
  }, []);

  return (
    <section
      className={`${styles.rail}${asDrawer ? ` ${styles.drawer}` : ''}`}
      aria-label="Folders"
    >
      {asDrawer && (
        <div className={styles.drawerHeader}>
          <span className={styles.drawerTitle}>Mailboxes</span>
          <button
            type="button"
            className={styles.drawerClose}
            onClick={() => typeof onClose === 'function' && onClose()}
            aria-label="Close navigation"
          >
            <X size={16} aria-hidden="true" />
          </button>
        </div>
      )}
      <button
        type="button"
        className={styles.compose}
        onClick={() => typeof onNewMessage === 'function' && onNewMessage()}
      >
        <Plus size={14} aria-hidden="true" />
        <span>New message</span>
      </button>

      <div className={`${styles.section} ${collapsed ? styles.collapsed : ''}`}>
        <div
          className={styles.sectionHeader}
          role="button"
          tabIndex={0}
          onClick={() => setCollapsed(c => !c)}
          onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') setCollapsed(c => !c); }}
          aria-expanded={!collapsed}
        >
          <span className={styles.chev}>
            <ChevronDown size={12} aria-hidden="true" />
          </span>
          <span className={styles.sectionLabel}>Folders</span>
          <span className={styles.sectionActions}>
            <button
              type="button"
              className={styles.sectionAction}
              title="New folder"
              aria-label="New folder"
              onClick={(e) => {
                e.stopPropagation();
                if (collapsed) setCollapsed(false);
                setAdding(true);
              }}
            >
              <Plus size={14} aria-hidden="true" />
            </button>
          </span>
        </div>

        <div className={styles.sectionBody}>
          <ul className={styles.folderList}>
            {items.map((f) => {
              const isActive = folder === f.id;
              const isFav = subscribed.includes(f.id);
              const canDelete = !PERMANENT_FOLDERS.includes(f.id);
              return (
                <li
                  key={f.id}
                  id={f.id}
                  className={`${styles.folderItem} ${isActive ? styles.active : ''}`}
                  onClick={() => handleSelect(f.id)}
                  role="button"
                  tabIndex={0}
                  onKeyDown={(e) => { if (e.key === 'Enter') handleSelect(f.id); }}
                  aria-current={isActive ? 'true' : undefined}
                >
                  <FolderIcon kind={f.kind} />
                  <span className={styles.folderName}>{f.label}</span>
                  <span className={styles.rowActions} onClick={(e) => e.stopPropagation()}>
                    <button
                      type="button"
                      className={`${styles.rowAction} ${isFav ? styles.favActive : ''}`}
                      title={isFav ? 'Unfavorite' : 'Favorite'}
                      aria-label={isFav ? `Unfavorite ${f.label}` : `Favorite ${f.label}`}
                      onClick={(e) => toggleSubscribe(e, f.id)}
                    >
                      <Star size={12} aria-hidden="true" />
                    </button>
                    {canDelete && (
                      <button
                        type="button"
                        className={styles.rowAction}
                        title={`Remove ${f.label}`}
                        aria-label={`Remove ${f.label}`}
                        onClick={(e) => removeFolder(e, f.id)}
                      >
                        <X size={12} aria-hidden="true" />
                      </button>
                    )}
                  </span>
                </li>
              );
            })}
          </ul>

          {adding ? (
            <div className={styles.addRow}>
              <Pencil size={14} aria-hidden="true" />
              <input
                autoFocus
                className={styles.addInput}
                placeholder="New folder name"
                value={newName}
                onChange={(e) => setNewName(e.target.value)}
                onBlur={commitAdd}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') commitAdd();
                  else if (e.key === 'Escape') cancelAdd();
                }}
              />
            </div>
          ) : (
            <button
              type="button"
              className={styles.addRow}
              onClick={() => setAdding(true)}
            >
              <Plus size={14} aria-hidden="true" />
              <span>New folder</span>
            </button>
          )}
        </div>
      </div>
    </section>
  );
}

export default Folders;
