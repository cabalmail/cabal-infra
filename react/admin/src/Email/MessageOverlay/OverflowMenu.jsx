import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  MoreHorizontal, Check,
  Palette, Code, Info, Forward, Printer,
  Archive, Ban, ShieldOff,
} from 'lucide-react';

/* =========================================================================
   Reader overflow menu — §4d.

   Phase 4 shipped the FORMAT group (Rich / Plain). Phase 5 adds the rest
   of the menu per the design spec:

     - Match app theme  — checkable, only when Rich mode is active.
     - View source
     - Show original headers  → opens the same modal pre-set to Headers
     - Forward as attachment
     - Print…
     - Archive
     - Mark as spam
     - Block sender  (destructive, --ink-danger)

   Keyboard behavior follows the pattern already established elsewhere in
   the app: arrow keys move focus between items, Enter / Space activates
   the focused item, Escape closes the menu.
   ========================================================================= */

const ITEM_SELECTOR = '[role="menuitem"], [role="menuitemcheckbox"]';

function MenuCheckItem({ checked, onClick, children }) {
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
      <span className="reader-menu-label">{children}</span>
    </button>
  );
}

function MenuActionItem({
  icon: Icon, onClick, disabled, danger, hint, children,
}) {
  return (
    <button
      type="button"
      className={`reader-menu-item ${danger ? 'danger' : ''}`}
      role="menuitem"
      onClick={onClick}
      disabled={disabled}
    >
      <span className="reader-menu-icon" aria-hidden="true">
        {Icon ? <Icon size={14} /> : null}
      </span>
      <span className="reader-menu-label">{children}</span>
      {hint && <span className="reader-menu-hint" aria-hidden="true">{hint}</span>}
    </button>
  );
}

function Separator() {
  return <div className="reader-menu-sep" role="separator" aria-hidden="true" />;
}

function OverflowMenu({
  format, setFormat, hasRich, hasPlain,
  matchTheme, setMatchTheme,
  onViewSource, onShowHeaders, onForwardAsAttachment, onPrint,
  onArchive, onMarkSpam, onBlockSender,
}) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef(null);
  const menuRef = useRef(null);
  const triggerRef = useRef(null);

  const showFormatGroup = hasRich && hasPlain;
  const inRichMode = format === 'rich' && hasRich;

  const close = useCallback(() => {
    setOpen(false);
    /* return focus to the trigger so keyboard flow is uninterrupted */
    if (triggerRef.current) triggerRef.current.focus();
  }, []);

  useEffect(() => {
    if (!open) return undefined;
    const onDocClick = (e) => {
      if (!rootRef.current) return;
      if (!rootRef.current.contains(e.target)) setOpen(false);
    };
    const onKey = (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        close();
        return;
      }
      if (!menuRef.current) return;
      const items = Array.from(menuRef.current.querySelectorAll(ITEM_SELECTOR))
        .filter((el) => !el.disabled);
      if (items.length === 0) return;
      const idx = items.indexOf(document.activeElement);
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        const next = idx < 0 ? 0 : (idx + 1) % items.length;
        items[next].focus();
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        const prev = idx <= 0 ? items.length - 1 : idx - 1;
        items[prev].focus();
      } else if (e.key === 'Home') {
        e.preventDefault();
        items[0].focus();
      } else if (e.key === 'End') {
        e.preventDefault();
        items[items.length - 1].focus();
      }
    };
    document.addEventListener('mousedown', onDocClick);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDocClick);
      document.removeEventListener('keydown', onKey);
    };
  }, [open, close]);

  // On open, move focus to the first interactive item so arrow keys work.
  useEffect(() => {
    if (!open || !menuRef.current) return;
    const first = menuRef.current.querySelector(ITEM_SELECTOR);
    if (first && !first.disabled) first.focus();
  }, [open]);

  const run = (fn) => () => {
    close();
    if (fn) fn();
  };

  const choose = (nextFormat) => {
    setFormat(nextFormat);
    /* keep the menu open so users can see the checkmark flip, matching
       the prototype behavior */
  };

  const toggleMatch = () => {
    if (setMatchTheme) setMatchTheme(!matchTheme);
  };

  return (
    <div className="reader-overflow" ref={rootRef}>
      <button
        ref={triggerRef}
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
        <div className="reader-menu" role="menu" ref={menuRef}>
          {showFormatGroup && (
            <>
              <div className="reader-menu-group-label">Format</div>
              <MenuCheckItem
                checked={format === 'rich'}
                onClick={() => choose('rich')}
              >
                Rich (HTML)
              </MenuCheckItem>
              <MenuCheckItem
                checked={format === 'plain'}
                onClick={() => choose('plain')}
              >
                Plain text alternative
              </MenuCheckItem>
              <Separator />
            </>
          )}

          {inRichMode && setMatchTheme && (
            <>
              <MenuCheckItem
                checked={!!matchTheme}
                onClick={toggleMatch}
              >
                Match app theme
              </MenuCheckItem>
              <Separator />
            </>
          )}

          <MenuActionItem icon={Code} onClick={run(onViewSource)}>
            View source
          </MenuActionItem>
          <MenuActionItem icon={Info} onClick={run(onShowHeaders)}>
            Show original headers
          </MenuActionItem>
          <MenuActionItem
            icon={Forward}
            onClick={run(onForwardAsAttachment)}
            disabled={!onForwardAsAttachment}
          >
            Forward as attachment
          </MenuActionItem>
          <MenuActionItem icon={Printer} onClick={run(onPrint)} hint="⌘P">
            Print…
          </MenuActionItem>
          <Separator />

          <MenuActionItem
            icon={Archive}
            onClick={run(onArchive)}
            disabled={!onArchive}
          >
            Archive
          </MenuActionItem>
          <MenuActionItem
            icon={Ban}
            onClick={run(onMarkSpam)}
            disabled={!onMarkSpam}
          >
            Mark as spam
          </MenuActionItem>
          <Separator />
          <MenuActionItem
            icon={ShieldOff}
            onClick={run(onBlockSender)}
            disabled={!onBlockSender}
            danger
          >
            Block sender
          </MenuActionItem>
        </div>
      )}
    </div>
  );
}

export default OverflowMenu;
