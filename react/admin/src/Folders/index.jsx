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

function FolderRow({
  f, isActive, isSubscribed, canDelete, onSelect, onToggleSubscribe, onRemove,
  depth = 0, showFullPath = false,
}) {
  const display = showFullPath && !f.system ? f.id : f.label;
  return (
    <li
      className={`${styles.folderItem} ${isActive ? styles.active : ''}`}
      style={depth > 0 ? { paddingLeft: `${12 + depth * 14}px` } : undefined}
      onClick={() => onSelect(f.id)}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => { if (e.key === 'Enter') onSelect(f.id); }}
      aria-current={isActive ? 'true' : undefined}
    >
      <FolderIcon kind={f.kind} />
      <span className={styles.folderName}>{display}</span>
      <span className={styles.rowActions} onClick={(e) => e.stopPropagation()}>
        <button
          type="button"
          className={`${styles.rowAction} ${isSubscribed ? styles.favActive : ''}`}
          title={isSubscribed ? 'Unsubscribe' : 'Subscribe'}
          aria-label={isSubscribed ? `Unsubscribe from ${f.label}` : `Subscribe to ${f.label}`}
          onClick={(e) => onToggleSubscribe(e, f.id)}
        >
          <Star size={12} aria-hidden="true" />
        </button>
        {canDelete && (
          <button
            type="button"
            className={styles.rowAction}
            title={`Remove ${f.label}`}
            aria-label={`Remove ${f.label}`}
            onClick={(e) => onRemove(e, f.id)}
          >
            <X size={12} aria-hidden="true" />
          </button>
        )}
      </span>
    </li>
  );
}

function Folders({ setMessage, folder, setFolder, onNewMessage, asDrawer = false, onClose }) {
  const api = useApi();
  const [folders, setFolders] = useState([]);
  const [subscribed, setSubscribed] = useState([]);
  const [collapsedSub, setCollapsedSub] = useState(false);
  const [collapsedAll, setCollapsedAll] = useState(false);
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
  const subscribedItems = useMemo(
    () => items.filter((f) => subscribed.includes(f.id)),
    [items, subscribed]
  );

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

      {subscribedItems.length > 0 && (
        <div className={`${styles.section} ${collapsedSub ? styles.collapsed : ''}`}>
          <div
            className={styles.sectionHeader}
            role="button"
            tabIndex={0}
            onClick={() => setCollapsedSub(c => !c)}
            onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') setCollapsedSub(c => !c); }}
            aria-expanded={!collapsedSub}
          >
            <span className={styles.chev}>
              <ChevronDown size={12} aria-hidden="true" />
            </span>
            <span className={styles.sectionLabel}>Subscribed</span>
          </div>

          <div className={styles.sectionBody}>
            <ul className={styles.folderList}>
              {subscribedItems.map((f) => (
                <FolderRow
                  key={f.id}
                  f={f}
                  isActive={folder === f.id}
                  isSubscribed
                  canDelete={!PERMANENT_FOLDERS.includes(f.id)}
                  onSelect={handleSelect}
                  onToggleSubscribe={toggleSubscribe}
                  onRemove={removeFolder}
                  showFullPath
                />
              ))}
            </ul>
          </div>
        </div>
      )}

      <div className={`${styles.section} ${collapsedAll ? styles.collapsed : ''}`}>
        <div
          className={styles.sectionHeader}
          role="button"
          tabIndex={0}
          onClick={() => setCollapsedAll(c => !c)}
          onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') setCollapsedAll(c => !c); }}
          aria-expanded={!collapsedAll}
        >
          <span className={styles.chev}>
            <ChevronDown size={12} aria-hidden="true" />
          </span>
          <span className={styles.sectionLabel}>All folders</span>
          <span className={styles.sectionActions}>
            <button
              type="button"
              className={styles.sectionAction}
              title="New folder"
              aria-label="New folder"
              onClick={(e) => {
                e.stopPropagation();
                if (collapsedAll) setCollapsedAll(false);
                setAdding(true);
              }}
            >
              <Plus size={14} aria-hidden="true" />
            </button>
          </span>
        </div>

        <div className={styles.sectionBody}>
          <ul className={styles.folderList}>
            {items.map((f) => (
              <FolderRow
                key={f.id}
                f={f}
                isActive={folder === f.id}
                isSubscribed={subscribed.includes(f.id)}
                canDelete={!PERMANENT_FOLDERS.includes(f.id)}
                onSelect={handleSelect}
                onToggleSubscribe={toggleSubscribe}
                onRemove={removeFolder}
                depth={f.depth}
              />
            ))}
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
