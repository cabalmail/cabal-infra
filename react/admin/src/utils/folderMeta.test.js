import { describe, it, expect } from 'vitest';
import { folderMeta, orderFolders } from './folderMeta';

describe('folderMeta', () => {
  it('classifies system folders with their kind and display label', () => {
    expect(folderMeta('INBOX')).toMatchObject({ kind: 'inbox', label: 'Inbox', system: true });
    expect(folderMeta('Drafts')).toMatchObject({ kind: 'drafts', label: 'Drafts', system: true });
    expect(folderMeta('Sent Messages')).toMatchObject({ kind: 'sent', label: 'Sent', system: true });
    expect(folderMeta('Archive')).toMatchObject({ kind: 'archive', label: 'Archive', system: true });
    expect(folderMeta('Deleted Messages')).toMatchObject({ kind: 'trash', label: 'Trash', system: true });
    expect(folderMeta('Junk')).toMatchObject({ kind: 'junk', label: 'Junk', system: true });
  });

  it('classifies custom folders as plain folders', () => {
    expect(folderMeta('Receipts')).toMatchObject({ kind: 'folder', label: 'Receipts', system: false });
  });
});

describe('orderFolders', () => {
  it('orders system folders in the §4b order, then custom ones alphabetically', () => {
    const input = [
      'Travel',
      'Junk',
      'Archive',
      'INBOX',
      'Newsletters',
      'Sent Messages',
      'Drafts',
      'Deleted Messages',
      'Receipts',
    ];
    const ordered = orderFolders(input).map((f) => f.id);
    expect(ordered).toEqual([
      'INBOX',
      'Drafts',
      'Sent Messages',
      'Archive',
      'Deleted Messages',
      'Junk',
      'Newsletters',
      'Receipts',
      'Travel',
    ]);
  });

  it('deduplicates identical folder names', () => {
    const ordered = orderFolders(['INBOX', 'INBOX', 'Receipts']);
    expect(ordered.map((f) => f.id)).toEqual(['INBOX', 'Receipts']);
  });
});
