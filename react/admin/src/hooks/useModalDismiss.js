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
 * @param {boolean} open Whether the modal is currently open.
 * @param {Function} onDismiss Called on Escape or a scrim hit.
 * @returns {{focusRef: object, onScrimHit: Function}} Ref for the control to
 *   focus on open, and the handler to bind to the scrim element.
 */
export default function useModalDismiss(open, onDismiss) {
  const focusRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    const onKey = (e) => { if (e.key === 'Escape') onDismiss(); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, onDismiss]);

  useEffect(() => {
    if (open && focusRef.current) focusRef.current.focus();
  }, [open]);

  const onScrimHit = useCallback((e) => {
    if (e.target === e.currentTarget) onDismiss();
  }, [onDismiss]);

  return { focusRef, onScrimHit };
}
