import { useCallback } from 'react';
import useModalDismiss from '../hooks/useModalDismiss';

function downloadXml(filename, text) {
  if (typeof window === 'undefined') return;
  const blob = new Blob([text || ''], { type: 'application/xml' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function XmlSourceModal({ open, title, filename, xmlText, loading, error, onClose }) {
  const { focusRef: closeRef, onScrimHit } = useModalDismiss(open, onClose);

  const copy = useCallback(async () => {
    try { await navigator.clipboard.writeText(xmlText || ''); } catch { /* noop */ }
  }, [xmlText]);

  const save = useCallback(() => {
    downloadXml(filename || 'dmarc-report.xml', xmlText || '');
  }, [filename, xmlText]);

  if (!open) return null;

  let inner;
  if (loading) {
    inner = <div className="source-status">Loading XML...</div>;
  } else if (error) {
    inner = <div className="source-status">Unable to load report XML.</div>;
  } else {
    inner = <span className="source-body-text">{xmlText}</span>;
  }

  return (
    <div className="source-scrim" onMouseDown={onScrimHit} role="presentation">
      <div className="source-window" role="dialog" aria-modal="true" aria-label="DMARC report XML">
        <div className="source-header">
          <div className="source-header-title">
            <span className="source-header-label">Report XML</span>
            <span className="source-header-subject" title={title}>{title || ''}</span>
          </div>
          <div className="source-header-tools">
            <button type="button" className="source-tool" onClick={copy} disabled={!xmlText}>Copy</button>
            <button type="button" className="source-tool" onClick={save} disabled={!xmlText}>Save .xml</button>
            <button
              type="button"
              className="source-close"
              ref={closeRef}
              onClick={onClose}
              aria-label="Close report XML"
            >
              &#x2715;
            </button>
          </div>
        </div>
        <pre className="source-body">{inner}</pre>
      </div>
    </div>
  );
}

export default XmlSourceModal;
