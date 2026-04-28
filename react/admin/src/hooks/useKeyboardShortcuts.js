import { useEffect, useRef } from 'react';

const GO_PREFIX_MS = 1500;

const GO_TARGETS = {
  i: 'INBOX',
  a: 'Archive',
  s: 'Sent Messages',
  t: 'Deleted Messages',
  d: 'Drafts',
};

function isTypingTarget(target) {
  if (!target) return false;
  const tag = target.tagName;
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return true;
  if (target.isContentEditable) return true;
  if (target.closest && target.closest('[contenteditable="true"]')) return true;
  return false;
}

/**
 * Unified keyboard-shortcut handler per Phase 7 / §Interactions. One
 * document-level keydown listener resolves single keys (j/k/Enter/e/#/r/a/
 * f/s/u/c/x/Esc/?), ⌘K / `/` for search, and `g` prefix chords (g i/a/s/
 * t/d) for folder navigation.
 *
 * Callers pass an object of optional callbacks; unmapped keys are no-ops
 * so the hook is safe to install before every consumer is wired. The
 * `enabled` flag lets callers pause handling (e.g. on the Login screen).
 */
export default function useKeyboardShortcuts(callbacks, enabled = true) {
  // Stash callbacks in a ref so the effect doesn't re-bind on every render.
  const cbRef = useRef(callbacks);
  useEffect(() => { cbRef.current = callbacks; }, [callbacks]);

  useEffect(() => {
    if (!enabled) return undefined;
    let goTimer = null;
    let awaitingGo = false;

    const clearGo = () => {
      if (goTimer) { clearTimeout(goTimer); goTimer = null; }
      awaitingGo = false;
    };

    const onKey = (e) => {
      // Ignore while the user is editing text.
      if (isTypingTarget(e.target)) {
        // Exception: ⌘K / Ctrl+K still focuses search even from an input.
        const isCmdK = (e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K');
        if (!isCmdK) return;
      }

      // ⌘K / Ctrl+K — focus search.
      if ((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K')) {
        if (cbRef.current.onFocusSearch) {
          e.preventDefault();
          cbRef.current.onFocusSearch();
        }
        return;
      }

      // Never interpret modified keys as single-letter shortcuts.
      if (e.metaKey || e.ctrlKey || e.altKey) return;

      // `g` prefix — arm a folder-nav chord for GO_PREFIX_MS.
      if (awaitingGo) {
        const target = GO_TARGETS[e.key];
        clearGo();
        if (target && cbRef.current.onGoToFolder) {
          e.preventDefault();
          cbRef.current.onGoToFolder(target);
        }
        return;
      }

      switch (e.key) {
        case 'g':
          awaitingGo = true;
          goTimer = setTimeout(clearGo, GO_PREFIX_MS);
          return;
        case '?':
          if (cbRef.current.onToggleHelp) {
            e.preventDefault();
            cbRef.current.onToggleHelp();
          }
          return;
        case '/':
          if (cbRef.current.onFocusSearch) {
            e.preventDefault();
            cbRef.current.onFocusSearch();
          }
          return;
        case 'Escape':
          if (cbRef.current.onEscape) cbRef.current.onEscape();
          return;
        case 'j':
          if (cbRef.current.onNext) { e.preventDefault(); cbRef.current.onNext(); }
          return;
        case 'k':
          if (cbRef.current.onPrev) { e.preventDefault(); cbRef.current.onPrev(); }
          return;
        case 'Enter':
          if (cbRef.current.onOpen) cbRef.current.onOpen();
          return;
        case 'e':
          if (cbRef.current.onArchive) { e.preventDefault(); cbRef.current.onArchive(); }
          return;
        case '#':
          if (cbRef.current.onDelete) { e.preventDefault(); cbRef.current.onDelete(); }
          return;
        case 'r':
          if (cbRef.current.onReply) { e.preventDefault(); cbRef.current.onReply(); }
          return;
        case 'a':
          if (cbRef.current.onReplyAll) { e.preventDefault(); cbRef.current.onReplyAll(); }
          return;
        case 'f':
          if (cbRef.current.onForward) { e.preventDefault(); cbRef.current.onForward(); }
          return;
        case 's':
          if (cbRef.current.onFlag) { e.preventDefault(); cbRef.current.onFlag(); }
          return;
        case 'u':
          if (cbRef.current.onMarkUnread) { e.preventDefault(); cbRef.current.onMarkUnread(); }
          return;
        case 'c':
          if (cbRef.current.onCompose) { e.preventDefault(); cbRef.current.onCompose(); }
          return;
        case 'x':
          if (cbRef.current.onToggleBulk) { e.preventDefault(); cbRef.current.onToggleBulk(); }
          return;
        default:
      }
    };

    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('keydown', onKey);
      clearGo();
    };
  }, [enabled]);
}

export { GO_TARGETS };
