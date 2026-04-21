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
  'Sent Messages':    { kind: 'sent',    label: 'Sent' },
  'Archive':          { kind: 'archive', label: 'Archive' },
  'Deleted Messages': { kind: 'trash',   label: 'Trash' },
  'Junk':             { kind: 'junk',    label: 'Junk' },
};

export function folderMeta(name) {
  if (Object.prototype.hasOwnProperty.call(SYSTEM_BY_NAME, name)) {
    return { id: name, ...SYSTEM_BY_NAME[name], system: true };
  }
  return { id: name, kind: 'folder', label: name, system: false };
}

function systemRank(kind) {
  const idx = SYSTEM_KINDS.indexOf(kind);
  return idx === -1 ? SYSTEM_KINDS.length : idx;
}

export function orderFolders(folders) {
  const seen = new Set();
  const metas = [];
  for (const name of folders) {
    if (seen.has(name)) continue;
    seen.add(name);
    metas.push(folderMeta(name));
  }
  metas.sort((a, b) => {
    if (a.system && b.system) return systemRank(a.kind) - systemRank(b.kind);
    if (a.system) return -1;
    if (b.system) return 1;
    return a.label.localeCompare(b.label);
  });
  return metas;
}
