import React, { useCallback, useEffect, useRef, useState } from 'react';
import { MoreHorizontal, Check } from 'lucide-react';

/* =========================================================================
   Reader overflow menu — §4d. Phase 4 lands only the FORMAT group
   (Rich / Plain text alternative); the rest of the items (View source,
   Show original headers, Forward as attachment, Print, Archive, Mark as
   spam, Block sender) are deferred to Phase 5 per the phased plan.

   The FORMAT group is only shown for messages that are multipart/
   alternative — i.e. when both plain and HTML bodies are present. If
   only one format exists the group would be degenerate.
   ========================================================================= */

function MenuItem({ checked, onClick, children }) {
  return (
    <button
      type="button"
      className="reader-menu-item"
      role="menuitemcheckbox"
      aria-checked={!!checked}
      onClick={onClick}
    >
      <span className="reader-menu-check" aria-hidden="true">
        {checked ? <Check size={14} /> : null}
      </span>
      {children}
    </button>
  );
}

function OverflowMenu({
  format, setFormat, hasRich, hasPlain,
}) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef(null);

  const showFormatGroup = hasRich && hasPlain;

  const close = useCallback(() => setOpen(false), []);

  useEffect(() => {
    if (!open) return undefined;
    const onDocClick = (e) => {
      if (!rootRef.current) return;
      if (!rootRef.current.contains(e.target)) close();
    };
    const onKey = (e) => {
      if (e.key === 'Escape') close();
    };
    document.addEventListener('mousedown', onDocClick);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDocClick);
      document.removeEventListener('keydown', onKey);
    };
  }, [open, close]);

  const choose = (nextFormat) => {
    setFormat(nextFormat);
    close();
  };

  return (
    <div className="reader-overflow" ref={rootRef}>
      <button
        type="button"
        className="reader-btn icon-only"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label="More actions"
        title="More actions"
        onClick={() => setOpen((v) => !v)}
      >
        <MoreHorizontal size={16} aria-hidden="true" />
      </button>
      {open && (
        <div className="reader-menu" role="menu">
          {showFormatGroup && (
            <>
              <div className="reader-menu-group-label">Format</div>
              <MenuItem
                checked={format === 'rich'}
                onClick={() => choose('rich')}
              >
                Rich (HTML)
              </MenuItem>
              <MenuItem
                checked={format === 'plain'}
                onClick={() => choose('plain')}
              >
                Plain text alternative
              </MenuItem>
            </>
          )}
          {!showFormatGroup && (
            <div
              className="reader-menu-group-label"
              style={{ color: 'var(--ink-quiet)', cursor: 'default' }}
            >
              No actions available
            </div>
          )}
        </div>
      )}
    </div>
  );
}

export default OverflowMenu;
