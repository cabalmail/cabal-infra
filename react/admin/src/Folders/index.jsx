import { Fragment, useCallback, useEffect, useMemo, useState } from 'react';
import {
  Archive,
  ChevronDown,
  FileText,
  Folder,
  Inbox,
  Pencil,
  Plus,
  RefreshCw,
  Send,
  ShieldAlert,
  Star,
  Trash2,
  X,
} from 'lucide-react';
import useApi from '../hooks/useApi';
import {
  FOLDER_COLLAPSED_ALL,
  FOLDER_COLLAPSED_PATHS,
  FOLDER_COLLAPSED_SUB,
  FOLDER_LIST,
  PERMANENT_FOLDERS,
} from '../constants';
import { ancestorsOf, orderFolders } from '../utils/folderMeta';
import styles from './Folders.module.css';

function readBool(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    if (raw === null) return fallback;
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

function readPathSet(key) {
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return new Set();
    const arr = JSON.parse(raw);
    return new Set(Array.isArray(arr) ? arr : []);
  } catch {
    return new Set();
  }
}

function writeJson(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch (e) {
    console.log(e);
  }
}

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
  onAddChild,
  depth = 0, showFullPath = false,
  hasChildren = false, isCollapsed = false, onToggleCollapse,
}) {
  const display = showFullPath && !f.system ? f.id : f.label;
  return (
    <li
      className={`${styles.folderItem} ${isActive ? styles.active : ''} ${isCollapsed ? styles.rowCollapsed : ''}`}
      style={depth > 0 ? { paddingLeft: `${12 + depth * 14}px` } : undefined}
      onClick={() => onSelect(f.id)}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => { if (e.key === 'Enter') onSelect(f.id); }}
      aria-current={isActive ? 'true' : undefined}
    >
      {hasChildren ? (
        <button
          type="button"
          className={styles.rowChev}
          title={isCollapsed ? `Expand ${f.label}` : `Collapse ${f.label}`}
          aria-label={isCollapsed ? `Expand ${f.label}` : `Collapse ${f.label}`}
          aria-expanded={!isCollapsed}
          onClick={(e) => {
            e.stopPropagation();
            onToggleCollapse(f.id);
          }}
        >
          <ChevronDown size={12} aria-hidden="true" />
        </button>
      ) : (
        <FolderIcon kind={f.kind} />
      )}
      <span className={styles.folderName}>{display}</span>
      <span className={styles.rowActions} onClick={(e) => e.stopPropagation()}>
        {onAddChild && (
          <button
            type="button"
            className={styles.rowAction}
            title={`New folder inside ${f.label}`}
            aria-label={`New folder inside ${f.label}`}
            onClick={(e) => onAddChild(e, f.id)}
          >
            <Plus size={12} aria-hidden="true" />
          </button>
        )}
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

function AddFolderInput({ value, onChange, onCommit, onCancel, depth = 0, asListItem = false }) {
  const style = depth > 0 ? { paddingLeft: `${12 + depth * 14}px` } : undefined;
  const content = (
    <>
      <Pencil size={14} aria-hidden="true" />
      <input
        autoFocus
        className={styles.addInput}
        placeholder="New folder name"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onBlur={onCommit}
        onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          if (e.key === 'Enter') onCommit();
          else if (e.key === 'Escape') onCancel();
        }}
      />
    </>
  );
  if (asListItem) {
    return <li className={styles.addRow} style={style}>{content}</li>;
  }
  return <div className={styles.addRow} style={style}>{content}</div>;
}

function Folders({ setMessage, folder, setFolder, onNewMessage, asDrawer = false, onClose }) {
  const api = useApi();
  const [folders, setFolders] = useState([]);
  const [subscribed, setSubscribed] = useState([]);
  const [collapsedSub, setCollapsedSub] = useState(() => readBool(FOLDER_COLLAPSED_SUB, false));
  const [collapsedAll, setCollapsedAll] = useState(() => readBool(FOLDER_COLLAPSED_ALL, false));
  const [collapsedFolders, setCollapsedFolders] = useState(() => readPathSet(FOLDER_COLLAPSED_PATHS));
  // null = not adding; '' = adding at root; folder id = adding under that folder
  const [addingParent, setAddingParent] = useState(null);
  const [newName, setNewName] = useState('');

  useEffect(() => { writeJson(FOLDER_COLLAPSED_SUB, collapsedSub); }, [collapsedSub]);
  useEffect(() => { writeJson(FOLDER_COLLAPSED_ALL, collapsedAll); }, [collapsedAll]);
  useEffect(() => { writeJson(FOLDER_COLLAPSED_PATHS, Array.from(collapsedFolders)); }, [collapsedFolders]);

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

  const presentIds = useMemo(() => new Set(items.map((f) => f.id)), [items]);

  // Auto-expand ancestors of the active selection so the user never loses
  // sight of the folder they're currently reading. Runs as an effect so the
  // persisted state stays consistent with what's on screen.
  useEffect(() => {
    if (!folder || collapsedFolders.size === 0) return;
    const ancestors = ancestorsOf(folder);
    if (ancestors.length === 0) return;
    let changed = false;
    const next = new Set(collapsedFolders);
    for (const a of ancestors) {
      if (next.delete(a)) changed = true;
    }
    if (changed) setCollapsedFolders(next);
  }, [folder, collapsedFolders]);

  const isHidden = useCallback((id) => {
    if (collapsedFolders.size === 0) return false;
    for (const a of ancestorsOf(id)) {
      if (collapsedFolders.has(a) && presentIds.has(a)) return true;
    }
    return false;
  }, [collapsedFolders, presentIds]);

  const visibleItems = useMemo(
    () => items.filter((f) => !isHidden(f.id)),
    [items, isHidden]
  );

  const toggleCollapse = useCallback((id) => {
    setCollapsedFolders((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

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
    if (addingParent === null) return;
    const name = newName.trim();
    if (!name) { setAddingParent(null); return; }
    if (name.includes('.') || name.includes('/')) {
      setMessage && setMessage("Folder names must not contain '.' or '/'.", true);
      return;
    }
    const parent = addingParent;
    api.newFolder(parent, name).then(() => {
      setAddingParent(null);
      setNewName('');
      localStorage.removeItem(FOLDER_LIST);
      refresh();
    }).catch(() => {
      setMessage && setMessage('Unable to create folder.', true);
    });
  }, [addingParent, api, newName, refresh, setMessage]);

  const cancelAdd = useCallback(() => {
    setAddingParent(null);
    setNewName('');
  }, []);

  const startAddChild = useCallback((e, id) => {
    e.stopPropagation();
    // Make sure the parent is expanded so the input — and the eventual new
    // child row — are visible.
    setCollapsedFolders((prev) => {
      if (!prev.has(id)) return prev;
      const next = new Set(prev);
      next.delete(id);
      return next;
    });
    if (collapsedAll) setCollapsedAll(false);
    setAddingParent(id);
  }, [collapsedAll]);

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
              title="Reload folders"
              aria-label="Reload folders"
              onClick={(e) => {
                e.stopPropagation();
                localStorage.removeItem(FOLDER_LIST);
                refresh();
              }}
            >
              <RefreshCw size={14} aria-hidden="true" />
            </button>
            <button
              type="button"
              className={styles.sectionAction}
              title="New folder"
              aria-label="New folder"
              onClick={(e) => {
                e.stopPropagation();
                if (collapsedAll) setCollapsedAll(false);
                setAddingParent('');
              }}
            >
              <Plus size={14} aria-hidden="true" />
            </button>
          </span>
        </div>

        <div className={styles.sectionBody}>
          <ul className={styles.folderList}>
            {visibleItems.map((f) => (
              <Fragment key={f.id}>
                <FolderRow
                  f={f}
                  isActive={folder === f.id}
                  isSubscribed={subscribed.includes(f.id)}
                  canDelete={!PERMANENT_FOLDERS.includes(f.id)}
                  onSelect={handleSelect}
                  onToggleSubscribe={toggleSubscribe}
                  onRemove={removeFolder}
                  onAddChild={startAddChild}
                  depth={f.depth}
                  hasChildren={f.hasChildren}
                  isCollapsed={collapsedFolders.has(f.id)}
                  onToggleCollapse={toggleCollapse}
                />
                {addingParent === f.id && (
                  <AddFolderInput
                    asListItem
                    depth={(f.depth || 0) + 1}
                    value={newName}
                    onChange={setNewName}
                    onCommit={commitAdd}
                    onCancel={cancelAdd}
                  />
                )}
              </Fragment>
            ))}
          </ul>

          {addingParent === '' ? (
            <AddFolderInput
              value={newName}
              onChange={setNewName}
              onCommit={commitAdd}
              onCancel={cancelAdd}
            />
          ) : addingParent === null ? (
            <button
              type="button"
              className={styles.addRow}
              onClick={() => setAddingParent('')}
            >
              <Plus size={14} aria-hidden="true" />
              <span>New folder</span>
            </button>
          ) : null}
        </div>
      </div>
    </section>
  );
}

export default Folders;
