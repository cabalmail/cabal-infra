/* =========================================================================
   Folder metadata for the left-rail Folders section (§4b).
   Classifies IMAP folder names into "kinds" used for icon + ordering, and
   maps the IMAP-native names onto the display labels the design calls for.
   ========================================================================= */

// Order follows §4b: Inbox, Drafts, Sent, Archive, Trash, Junk, then custom.
const SYSTEM_KINDS = ['inbox', 'drafts', 'sent', 'archive', 'trash', 'junk'];

const SYSTEM_BY_NAME = {
  'INBOX':            { kind: 'inbox',   label: 'Inbox' },
  'Drafts':           { kind: 'drafts',  label: 'Drafts' },
  // 'Sent' is Dovecot's special-use \Sent mailbox, the folder the server
  // appends sent copies to and the one the Apple clients use. Legacy
  // 'Sent Messages' folders deliberately fall through to ordinary-folder
  // treatment.
  'Sent':             { kind: 'sent',    label: 'Sent' },
  'Archive':          { kind: 'archive', label: 'Archive' },
  'Deleted Messages': { kind: 'trash',   label: 'Trash' },
  'Junk':             { kind: 'junk',    label: 'Junk' },
};

function isSystem(name) {
  return Object.prototype.hasOwnProperty.call(SYSTEM_BY_NAME, name);
}

export function folderMeta(name) {
  if (isSystem(name)) {
    return { id: name, ...SYSTEM_BY_NAME[name], system: true, depth: 0 };
  }
  const segs = name.split('/');
  return {
    id: name,
    kind: 'folder',
    label: segs[segs.length - 1],
    system: false,
    depth: segs.length - 1,
  };
}

function systemRank(kind) {
  const idx = SYSTEM_KINDS.indexOf(kind);
  return idx === -1 ? SYSTEM_KINDS.length : idx;
}

// DFS through the implicit `/`-delimited tree formed by the names so peers
// sort alphabetically and children appear directly under their parent.
// Intermediate segments that aren't themselves in `names` are not emitted —
// we don't fabricate rows for folders that don't exist on the server.
function sortUserTree(names) {
  const present = new Set(names);
  const root = new Map();
  for (const name of names) {
    const segs = name.split('/');
    let node = root;
    let acc = '';
    for (const seg of segs) {
      acc = acc ? `${acc}/${seg}` : seg;
      if (!node.has(seg)) {
        node.set(seg, { path: acc, children: new Map() });
      }
      node = node.get(seg).children;
    }
  }
  const out = [];
  const walk = (map) => {
    const entries = Array.from(map.entries())
      .sort(([a], [b]) => a.localeCompare(b, undefined, { sensitivity: 'base' }));
    for (const [, { path, children }] of entries) {
      if (present.has(path)) out.push(path);
      walk(children);
    }
  };
  walk(root);
  return out;
}

export function orderFolders(folders) {
  const seen = new Set();
  const uniq = [];
  for (const name of folders) {
    if (seen.has(name)) continue;
    seen.add(name);
    uniq.push(name);
  }
  const systemSorted = uniq
    .filter(isSystem)
    .map(folderMeta)
    .sort((a, b) => systemRank(a.kind) - systemRank(b.kind));
  const userSorted = sortUserTree(uniq.filter((n) => !isSystem(n))).map(folderMeta);
  const ordered = [...systemSorted, ...userSorted];
  // hasChildren is true iff some other present, non-system folder lives under
  // this one. Only used to decide whether to render a collapse chevron.
  const present = new Set(ordered.map((f) => f.id));
  return ordered.map((f) => ({
    ...f,
    hasChildren: !f.system && hasDescendant(f.id, present),
  }));
}

function hasDescendant(id, present) {
  const prefix = `${id}/`;
  for (const candidate of present) {
    if (candidate !== id && candidate.startsWith(prefix)) return true;
  }
  return false;
}

// Walk ancestor paths of `id`, e.g. "Work/Q1/Archive" -> ["Work", "Work/Q1"].
export function ancestorsOf(id) {
  const segs = id.split('/');
  const out = [];
  let acc = '';
  for (let i = 0; i < segs.length - 1; i += 1) {
    acc = acc ? `${acc}/${segs[i]}` : segs[i];
    out.push(acc);
  }
  return out;
}
