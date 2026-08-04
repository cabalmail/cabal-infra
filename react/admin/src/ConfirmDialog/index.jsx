import { X } from 'lucide-react';
import useModalDismiss from '../hooks/useModalDismiss';
import styles from './ConfirmDialog.module.css';

function ConfirmDialog({
  open,
  title,
  message,
  confirmLabel = 'Confirm',
  cancelLabel = 'Cancel',
  destructive = false,
  onConfirm,
  onCancel,
}) {
  const { focusRef: confirmRef, onScrimHit } = useModalDismiss(open, onCancel);

  if (!open) return null;

  return (
    <div
      className={styles.scrim}
      onClick={onScrimHit}
      role="presentation"
    >
      <div
        className={styles.dialog}
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="confirm-dialog-title"
      >
        <div className={styles.head}>
          <span id="confirm-dialog-title">{title}</span>
          <button
            type="button"
            className={styles.close}
            aria-label="Close"
            onClick={onCancel}
          >
            <X size={14} aria-hidden="true" />
          </button>
        </div>
        <div className={styles.body}>{message}</div>
        <div className={styles.actions}>
          <button
            type="button"
            className={styles.cancel}
            onClick={onCancel}
          >
            {cancelLabel}
          </button>
          <button
            type="button"
            ref={confirmRef}
            className={destructive ? styles.confirmDestructive : styles.confirm}
            onClick={onConfirm}
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}

export default ConfirmDialog;
