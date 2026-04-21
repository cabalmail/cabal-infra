import { useEffect, useRef } from 'react';
import { X } from 'lucide-react';
import './KeyboardHelp.css';

const GROUPS = [
  {
    heading: 'Navigation',
    rows: [
      { keys: ['j'],           label: 'Next message' },
      { keys: ['k'],           label: 'Previous message' },
      { keys: ['Enter'],       label: 'Open selected message' },
      { keys: ['Esc'],         label: 'Close overlay · exit bulk mode' },
    ],
  },
  {
    heading: 'Message actions',
    rows: [
      { keys: ['r'],           label: 'Reply' },
      { keys: ['a'],           label: 'Reply all' },
      { keys: ['f'],           label: 'Forward' },
      { keys: ['e'],           label: 'Archive' },
      { keys: ['#'],           label: 'Delete' },
      { keys: ['s'],           label: 'Flag / unflag' },
      { keys: ['u'],           label: 'Mark unread' },
      { keys: ['x'],           label: 'Toggle bulk select' },
    ],
  },
  {
    heading: 'App',
    rows: [
      { keys: ['c'],           label: 'Compose new message' },
      { keys: ['⌘', 'K'],      label: 'Focus search' },
      { keys: ['/'],           label: 'Focus search' },
      { keys: ['?'],           label: 'Toggle this help' },
    ],
  },
  {
    heading: 'Go to folder',
    rows: [
      { keys: ['g', 'i'],      label: 'Inbox' },
      { keys: ['g', 'a'],      label: 'Archive' },
      { keys: ['g', 's'],      label: 'Sent' },
      { keys: ['g', 't'],      label: 'Trash' },
      { keys: ['g', 'd'],      label: 'Drafts' },
    ],
  },
];

export default function KeyboardHelp({ open, onClose }) {
  const dialogRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    const prev = document.activeElement;
    dialogRef.current?.focus();
    return () => {
      if (prev && prev.focus) prev.focus();
    };
  }, [open]);

  if (!open) return null;

  return (
    <div
      className="kbd-help__scrim"
      role="presentation"
      onClick={onClose}
    >
      <div
        ref={dialogRef}
        className="kbd-help"
        role="dialog"
        aria-modal="true"
        aria-labelledby="kbd-help-title"
        tabIndex={-1}
        onClick={(e) => e.stopPropagation()}
      >
        <header className="kbd-help__header">
          <h2 id="kbd-help-title" className="kbd-help__title">Keyboard shortcuts</h2>
          <button
            type="button"
            className="kbd-help__close"
            aria-label="Close"
            onClick={onClose}
          >
            <X size={16} aria-hidden="true" />
          </button>
        </header>
        <div className="kbd-help__body">
          {GROUPS.map(group => (
            <section key={group.heading} className="kbd-help__group">
              <h3 className="kbd-help__group-title">{group.heading}</h3>
              <dl className="kbd-help__rows">
                {group.rows.map(row => (
                  <div key={row.label} className="kbd-help__row">
                    <dt className="kbd-help__keys">
                      {row.keys.map((k, i) => (
                        <kbd key={i} className="kbd-help__kbd">{k}</kbd>
                      ))}
                    </dt>
                    <dd className="kbd-help__label">{row.label}</dd>
                  </div>
                ))}
              </dl>
            </section>
          ))}
        </div>
        <footer className="kbd-help__footer">
          Press <kbd className="kbd-help__kbd">?</kbd> to toggle this panel.
        </footer>
      </div>
    </div>
  );
}
