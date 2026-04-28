import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { X } from 'lucide-react';
import { parseEmlSource } from '../../utils/emlSource';

/* =========================================================================
   Reader — View source modal (§4d, Phase 5).

   A 880px × 80vh modal that renders the raw RFC-822 source of the current
   message in three views via the segmented control:

     - Full:    colored headers + separator + raw body
     - Headers: colored headers only
     - Body:    raw body only

   Copy puts the raw text (always the Full view's source, regardless of
   tab) on the clipboard. Save downloads `<subject>.eml` with the
   message/rfc822 MIME type. The modal also doubles as the "Show original
   headers" target when opened with initialTab="headers".
   ========================================================================= */

const TABS = ['full', 'headers', 'body'];
const TAB_LABELS = { full: 'Full', headers: 'Headers', body: 'Body' };

function sanitizeFilename(subject) {
  const base = (subject || 'message').trim().slice(0, 80);
  const cleaned = base.replace(/[\\/:*?"<>|\n\r\t]+/g, '_').replace(/^\.+/, '');
  return `${cleaned || 'message'}.eml`;
}

function downloadEml(subject, rawText) {
  if (typeof window === 'undefined') return;
  const blob = new Blob([rawText], { type: 'message/rfc822' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = sanitizeFilename(subject);
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function ViewSourceModal({
  open, subject, rawText, loading, error, onClose, initialTab = 'full',
}) {
  const [tab, setTab] = useState(initialTab);
  const [copied, setCopied] = useState(false);
  const closeRef = useRef(null);

  // Re-sync the tab whenever the modal is (re)opened — the same component
  // is reused for both "View source" and "Show original headers" entry
  // points and they default to different initial tabs.
  useEffect(() => {
    if (open) setTab(initialTab);
  }, [open, initialTab]);

  useEffect(() => {
    if (!open) return undefined;
    const onKey = (e) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, onClose]);

  useEffect(() => {
    if (open && closeRef.current) closeRef.current.focus();
  }, [open]);

  const { headers, body } = useMemo(() => parseEmlSource(rawText), [rawText]);

  const onScrimMouseDown = useCallback((e) => {
    if (e.target === e.currentTarget) onClose();
  }, [onClose]);

  const copy = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(rawText || '');
      setCopied(true);
      setTimeout(() => setCopied(false), 1400);
    } catch {
      /* clipboard blocked — no-op */
    }
  }, [rawText]);

  const save = useCallback(() => {
    downloadEml(subject, rawText || '');
  }, [subject, rawText]);

  if (!open) return null;

  const renderHeaders = () => headers.map(([name, value], i) => (
    <div key={`${name}-${i}`} className="source-hdr-row">
      <span className="hdr-name">{name}:</span>
      {' '}
      <span>{value}</span>
    </div>
  ));

  const renderBody = () => (
    <span className="source-body-text">{body}</span>
  );

  let inner;
  if (loading) {
    inner = <div className="source-status">Loading source…</div>;
  } else if (error) {
    inner = <div className="source-status">Unable to load raw source.</div>;
  } else if (tab === 'headers') {
    inner = renderHeaders();
  } else if (tab === 'body') {
    inner = renderBody();
  } else {
    inner = (
      <>
        {renderHeaders()}
        <div className="hdr-sep" role="separator" />
        {renderBody()}
      </>
    );
  }

  return (
    <div
      className="source-scrim"
      onMouseDown={onScrimMouseDown}
      role="presentation"
    >
      <div
        className="source-window"
        role="dialog"
        aria-modal="true"
        aria-label="Message source"
      >
        <div className="source-header">
          <div className="source-header-title">
            <span className="source-header-label">Message source</span>
            <span className="source-header-subject" title={subject}>
              {subject || '(no subject)'}
            </span>
          </div>
          <div className="source-header-tools">
            <div className="source-seg" role="tablist" aria-label="View">
              {TABS.map((key) => (
                <button
                  key={key}
                  type="button"
                  role="tab"
                  aria-selected={tab === key}
                  className={`source-seg-btn ${tab === key ? 'active' : ''}`}
                  onClick={() => setTab(key)}
                >
                  {TAB_LABELS[key]}
                </button>
              ))}
            </div>
            <button
              type="button"
              className="source-tool"
              onClick={copy}
              disabled={!rawText}
            >
              {copied ? '✓ Copied' : 'Copy'}
            </button>
            <button
              type="button"
              className="source-tool"
              onClick={save}
              disabled={!rawText}
            >
              Save .eml
            </button>
            <button
              type="button"
              className="source-close"
              ref={closeRef}
              onClick={onClose}
              aria-label="Close message source"
            >
              <X size={14} aria-hidden="true" />
            </button>
          </div>
        </div>
        <pre className="source-body">{inner}</pre>
      </div>
    </div>
  );
}

export default ViewSourceModal;
