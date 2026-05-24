import { describe, it, expect } from 'vitest';
import { ancestorsOf, folderMeta, orderFolders } from './folderMeta';

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

  it('arranges user folders into a /-delimited tree with peers alphabetical', () => {
    const ordered = orderFolders([
      'Projects/Zeta',
      'Projects',
      'Projects/Alpha/Sub',
      'Projects/Alpha',
      'Newsletters',
    ]);
    expect(ordered.map((f) => ({ id: f.id, label: f.label, depth: f.depth }))).toEqual([
      { id: 'Newsletters',          label: 'Newsletters', depth: 0 },
      { id: 'Projects',             label: 'Projects',    depth: 0 },
      { id: 'Projects/Alpha',       label: 'Alpha',       depth: 1 },
      { id: 'Projects/Alpha/Sub',   label: 'Sub',         depth: 2 },
      { id: 'Projects/Zeta',        label: 'Zeta',        depth: 1 },
    ]);
  });

  it('skips intermediate path segments that are not themselves folders', () => {
    const ordered = orderFolders(['Projects/Alpha', 'Other']);
    expect(ordered.map((f) => f.id)).toEqual(['Other', 'Projects/Alpha']);
  });

  it('marks user folders with descendants as hasChildren, leaves leaves alone', () => {
    const ordered = orderFolders(['INBOX', 'Work', 'Work/Q1', 'Receipts']);
    const byId = Object.fromEntries(ordered.map((f) => [f.id, f.hasChildren]));
    expect(byId).toEqual({
      INBOX: false,
      Work: true,
      'Work/Q1': false,
      Receipts: false,
    });
  });
});

describe('ancestorsOf', () => {
  it('returns each /-delimited parent up to but not including the leaf', () => {
    expect(ancestorsOf('Work')).toEqual([]);
    expect(ancestorsOf('Work/Q1')).toEqual(['Work']);
    expect(ancestorsOf('Work/Q1/Archive')).toEqual(['Work', 'Work/Q1']);
  });
});
