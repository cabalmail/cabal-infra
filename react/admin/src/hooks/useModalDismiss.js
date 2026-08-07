import { useCallback, useEffect, useRef } from 'react';

/**
 * Shared dismissal wiring for the scrim-and-window modals (ConfirmDialog,
 * ViewSourceModal, XmlSourceModal, DnsCheckModal). Each of them needs the
 * same three things while open: Escape closes, focus lands on one control
 * when the modal opens, and a pointer event on the scrim itself — never on
 * a child — closes.
 *
 * The listener is only attached while `open` is true, so a closed modal
 * that is still mounted does not swallow Escape from whatever is behind it.
 *
 * While open it takes the key in the capture phase and stops propagation,
 * so Escape closes the topmost layer only. The app-level shortcut hook
 * (which closes the reader on Escape) also listens on `document`, but in
 * the bubble phase — a real keydown targets the focused element inside the
 * modal, so capture always runs first and the bubble listener never sees it.
 *
 * @param {boolean} open Whether the modal is currently open.
 * @param {Function} onDismiss Called on Escape or a scrim hit.
 * @returns {{focusRef: object, onScrimHit: Function}} Ref for the control to
 *   focus on open, and the handler to bind to the scrim element.
 */
export default function useModalDismiss(open, onDismiss) {
  const focusRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    const onKey = (e) => {
      if (e.key !== 'Escape') return;
      e.preventDefault();
      e.stopPropagation();
      onDismiss();
    };
    document.addEventListener('keydown', onKey, true);
    return () => document.removeEventListener('keydown', onKey, true);
  }, [open, onDismiss]);

  useEffect(() => {
    if (open && focusRef.current) focusRef.current.focus();
  }, [open]);

  const onScrimHit = useCallback((e) => {
    if (e.target === e.currentTarget) onDismiss();
  }, [onDismiss]);

  return { focusRef, onScrimHit };
}
