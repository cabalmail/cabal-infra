/**
 * Reader — §4d. Phase 5 adds:
 *   - View source modal (Full / Headers / Body, Copy, Save .eml),
 *   - Match theme toggle + iframe style injection,
 *   - the remaining overflow-menu items.
 */

import React, {
  useCallback, useEffect, useMemo, useState,
} from 'react';
import {
  Reply, ReplyAll, Forward,
  Archive, FolderInput, Trash2, Flag, MailOpen, X,
} from 'lucide-react';
import ReaderBody from './ReaderBody';
import Attachments from './Attachments';
import OverflowMenu from './OverflowMenu';
import ViewSourceModal from './ViewSourceModal';
import useApi from '../../hooks/useApi';
import { useAppMessage } from '../../contexts/AppMessageContext';
import {
  READ, UNREAD, FLAGGED, ARRIVAL,
} from '../../constants';
import {
  extractName, extractEmail, formatReaderTimestamp, initialsFor,
} from '../../utils/formatDate';
import './MessageOverlay.css';

function MessageOverlay({
  envelope, folder, visible, flags,
  hide: hideProp, updateOverlay,
  reply: replyProp, replyAll: replyAllProp, forward: forwardProp,
  readerFormat, setReaderFormat,
}) {
  const api = useApi();
  const { setMessage } = useAppMessage();

  const [messageBodyPlain, setMessageBodyPlain] = useState('');
  const [messageBodyHtml, setMessageBodyHtml] = useState('');
  const [attachments, setAttachments] = useState([]);
  const [loading, setLoading] = useState(true);
  const [recipient, setRecipient] = useState('');
  const [messageId, setMessageId] = useState([]);
  const [inReplyTo, setInReplyTo] = useState([]);
  const [references, setReferences] = useState([]);
  const [messageRawUrl, setMessageRawUrl] = useState(null);

  // Match theme (§4d, Phase 5). Local — one toggle per reader session.
  // Only meaningful in Rich mode; the OverflowMenu hides it otherwise.
  const [matchTheme, setMatchTheme] = useState(false);

  // View source modal state. `initialTab` is 'full' when triggered from
  // "View source" and 'headers' when triggered from "Show original
  // headers". `rawText` is lazy-loaded the first time the modal opens.
  const [sourceOpen, setSourceOpen] = useState(false);
  const [sourceInitialTab, setSourceInitialTab] = useState('full');
  const [rawText, setRawText] = useState('');
  const [rawLoading, setRawLoading] = useState(false);
  const [rawError, setRawError] = useState(false);

  const envelopeId = envelope && envelope.id;
  const seen = envelope && envelope.flags
    ? envelope.flags.includes('\\Seen')
    : false;
  const isFlagged = (flags || []).includes('\\Flagged');
  const isSeen = (flags || []).includes('\\Seen');

  useEffect(() => {
    if (!envelopeId) return;
    setLoading(true);
    setMessageBodyHtml('');
    setMessageBodyPlain('');
    setAttachments([]);
    setMessageRawUrl(null);
    setRawText('');
    setRawError(false);
    setSourceOpen(false);
    setMatchTheme(false);

    api.getMessage(folder, envelopeId, seen).then((data) => {
      setMessageBodyPlain(data.data.message_body_plain || '');
      setMessageBodyHtml(data.data.message_body_html || '');
      setRecipient(data.data.recipient || '');
      setMessageId(data.data.message_id || []);
      setInReplyTo(data.data.in_reply_to || []);
      setReferences(data.data.references || []);
      setMessageRawUrl(data.data.message_raw || null);
      setLoading(false);
    }).catch((e) => {
      setMessage('Unable to get message.', true);
      console.log(e);
    });

    api.getAttachments(folder, envelopeId, seen).then((data) => {
      setAttachments(data.data.attachments || []);
    }).catch((e) => {
      setMessage('Unable to get list of attachments.', true);
      console.log(e);
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [envelopeId]);

  const hasRich = !!messageBodyHtml;
  const hasPlain = !!messageBodyPlain;

  // Clamp format to what's actually available for this message. The state
  // bag itself remains whatever the user chose — we just degrade the view
  // when the chosen format isn't present.
  const effectiveFormat = (readerFormat === 'rich' && !hasRich)
    ? 'plain'
    : (readerFormat === 'plain' && !hasPlain && hasRich)
      ? 'rich'
      : readerFormat;

  const hide = useCallback((e) => {
    if (e) e.preventDefault();
    hideProp();
  }, [hideProp]);

  const refreshEnvelope = useCallback(() => {
    if (!envelopeId) return;
    api.getEnvelopes(folder, [envelopeId]).then((data) => {
      const next = data.data.envelopes[envelopeId];
      if (next) updateOverlay(next);
    });
  }, [api, folder, envelopeId, updateOverlay]);

  const runFlag = useCallback((spec) => {
    if (!envelopeId) return;
    api.setFlag(folder, spec.imap, spec.op, [envelopeId], '', ARRIVAL.imap)
      .then(refreshEnvelope)
      .catch((err) => {
        setMessage('Unable to set flag on message.', true);
        console.log(err);
      });
  }, [api, folder, envelopeId, refreshEnvelope, setMessage]);

  const doArchive = useCallback(() => {
    if (!envelopeId) return;
    api.moveMessages(folder, 'Archive', [envelopeId], '', ARRIVAL.imap)
      .then(() => hide())
      .catch((err) => {
        setMessage('Unable to archive message.', true);
        console.log(err);
      });
  }, [api, folder, envelopeId, hide, setMessage]);

  const doDelete = useCallback(() => {
    if (!envelopeId) return;
    api.moveMessages(folder, 'Deleted Messages', [envelopeId], '', ARRIVAL.imap)
      .then(() => hide())
      .catch((err) => {
        setMessage('Unable to delete message.', true);
        console.log(err);
      });
  }, [api, folder, envelopeId, hide, setMessage]);

  const doMarkSpam = useCallback(() => {
    if (!envelopeId) return;
    api.moveMessages(folder, 'Junk', [envelopeId], '', ARRIVAL.imap)
      .then(() => hide())
      .catch((err) => {
        setMessage('Unable to mark as spam.', true);
        console.log(err);
      });
  }, [api, folder, envelopeId, hide, setMessage]);

  const toggleFlagged = useCallback(() => {
    runFlag(isFlagged ? { ...FLAGGED, op: 'unset' } : FLAGGED);
  }, [isFlagged, runFlag]);

  const markUnread = useCallback(() => {
    if (!isSeen) return;
    runFlag(UNREAD);
  }, [isSeen, runFlag]);

  const markRead = useCallback(() => {
    if (isSeen) return;
    runFlag(READ);
  }, [isSeen, runFlag]);

  const createPayload = useCallback(() => [
    recipient,
    messageBodyHtml || messageBodyPlain,
    envelope,
    { message_id: messageId, in_reply_to: inReplyTo, references },
  ], [recipient, messageBodyHtml, messageBodyPlain, envelope, messageId, inReplyTo, references]);

  const reply = useCallback(() => {
    const [r, b, e, h] = createPayload();
    replyProp(r, b, e, h);
  }, [createPayload, replyProp]);

  const replyAll = useCallback(() => {
    const [r, b, e, h] = createPayload();
    replyAllProp(r, b, e, h);
  }, [createPayload, replyAllProp]);

  const forward = useCallback(() => {
    const [r, b, e, h] = createPayload();
    forwardProp(r, b, e, h);
  }, [createPayload, forwardProp]);

  const downloadAttachment = useCallback((id) => {
    const a = attachments.find((att) => att.id === id);
    if (!a || !envelopeId) return;
    api.getAttachment(a, folder, envelopeId, seen)
      .then((data) => window.open(data.data.url))
      .catch(() => setMessage('Unable to download attachment.', true));
  }, [api, attachments, folder, envelopeId, seen, setMessage]);

  /* Fetch the raw .eml on first open of the View source modal and cache
     it. Subsequent opens (for the same envelope) reuse the cached text;
     `rawText` is cleared whenever the envelope changes. */
  const ensureRawText = useCallback(() => {
    if (rawText || rawLoading) return;
    if (!messageRawUrl) {
      setRawError(true);
      return;
    }
    setRawLoading(true);
    setRawError(false);
    api.getRawMessage(messageRawUrl)
      .then((r) => {
        setRawText(typeof r.data === 'string' ? r.data : String(r.data || ''));
      })
      .catch(() => {
        setRawError(true);
        setMessage('Unable to load message source.', true);
      })
      .finally(() => setRawLoading(false));
  }, [rawText, rawLoading, messageRawUrl, api, setMessage]);

  const openViewSource = useCallback(() => {
    setSourceInitialTab('full');
    setSourceOpen(true);
    ensureRawText();
  }, [ensureRawText]);

  const openHeaders = useCallback(() => {
    setSourceInitialTab('headers');
    setSourceOpen(true);
    ensureRawText();
  }, [ensureRawText]);

  const closeSource = useCallback(() => setSourceOpen(false), []);

  const forwardAsAttachment = useCallback(() => {
    /* Forward-as-attachment is called out in the plan as a stub — the
       backing flow (attach raw .eml to a new compose) lands later. For
       now we surface an informational toast so the button is non-silent
       but does nothing destructive. */
    setMessage('Forward as attachment is not available yet.', false);
  }, [setMessage]);

  const doPrint = useCallback(() => {
    if (typeof window !== 'undefined' && window.print) window.print();
  }, []);

  const blockSender = useCallback(() => {
    /* Block sender is a gating feature that needs server-side support
       (filter rules per §1.3). Until that lands, show a toast instead
       of a no-op. */
    setMessage('Block sender is not available yet.', false);
  }, [setMessage]);

  const sourceSubject = useMemo(
    () => (envelope && envelope.subject) || '',
    [envelope],
  );

  if (!visible) {
    return <div className="reader overlay_hidden" />;
  }

  if (loading || !envelopeId) {
    return (
      <div className="reader">
        <div className="reader-actions" aria-label="Message actions" />
        <div className="reader-scroll">
          <div className="reader-loading">Loading…</div>
        </div>
      </div>
    );
  }

  const senderRaw = (envelope.from && envelope.from[0]) || '';
  const senderName = extractName(senderRaw) || senderRaw || 'Unknown sender';
  const senderEmail = extractEmail(senderRaw);
  const initials = initialsFor(senderRaw);
  const toList = (envelope.to && envelope.to.length)
    ? envelope.to.join(', ')
    : 'Undisclosed recipients';
  const timestamp = formatReaderTimestamp(envelope.date);

  return (
    <div className="reader" role="region" aria-label="Message">
      <div className="reader-actions" role="toolbar" aria-label="Message actions">
        <button type="button" className="reader-btn" onClick={reply} title="Reply">
          <Reply size={16} aria-hidden="true" />
          <span className="reader-btn-label">Reply</span>
        </button>
        <button type="button" className="reader-btn" onClick={replyAll} title="Reply all">
          <ReplyAll size={16} aria-hidden="true" />
          <span className="reader-btn-label">Reply all</span>
        </button>
        <button type="button" className="reader-btn" onClick={forward} title="Forward">
          <Forward size={16} aria-hidden="true" />
          <span className="reader-btn-label">Forward</span>
        </button>

        <span className="reader-sep" aria-hidden="true" />

        <button
          type="button"
          className="reader-btn icon-only"
          onClick={doArchive}
          title="Archive"
          aria-label="Archive"
        >
          <Archive size={16} aria-hidden="true" />
        </button>
        <button
          type="button"
          className="reader-btn icon-only"
          onClick={() => setMessage('Move is coming in a later phase.', false)}
          title="Move"
          aria-label="Move"
          disabled
        >
          <FolderInput size={16} aria-hidden="true" />
        </button>
        <button
          type="button"
          className="reader-btn icon-only"
          onClick={doDelete}
          title="Delete"
          aria-label="Delete"
        >
          <Trash2 size={16} aria-hidden="true" />
        </button>
        <button
          type="button"
          className={`reader-btn icon-only ${isFlagged ? 'flagged' : ''}`}
          onClick={toggleFlagged}
          title={isFlagged ? 'Unflag' : 'Flag'}
          aria-label={isFlagged ? 'Unflag' : 'Flag'}
          aria-pressed={isFlagged}
        >
          <Flag size={16} aria-hidden="true" />
        </button>
        <button
          type="button"
          className="reader-btn icon-only"
          onClick={markUnread}
          title="Mark unread"
          aria-label="Mark unread"
          disabled={!isSeen}
        >
          <MailOpen size={16} aria-hidden="true" />
        </button>

        <span className="reader-spacer" />

        <OverflowMenu
          format={effectiveFormat}
          setFormat={setReaderFormat}
          hasRich={hasRich}
          hasPlain={hasPlain}
          matchTheme={matchTheme}
          setMatchTheme={setMatchTheme}
          onViewSource={openViewSource}
          onShowHeaders={openHeaders}
          onForwardAsAttachment={forwardAsAttachment}
          onPrint={doPrint}
          onArchive={doArchive}
          onMarkSpam={doMarkSpam}
          onBlockSender={blockSender}
        />

        <button
          type="button"
          className="reader-btn icon-only close_overlay"
          onClick={hide}
          title="Close message"
          aria-label="Close message"
        >
          <X size={16} aria-hidden="true" />
        </button>
      </div>

      <div className="reader-scroll">
        <header className="reader-header">
          <span className="reader-avatar" aria-hidden="true">{initials}</span>
          <h1 className="reader-subject">{envelope.subject || '(no subject)'}</h1>
          <div className="reader-sender">
            <span className="reader-sender-name">{senderName}</span>
            {senderEmail && (
              <span className="reader-sender-email">&lt;{senderEmail}&gt;</span>
            )}
          </div>
          <div className="reader-timestamp">{timestamp}</div>
          <div className="reader-to">
            <span className="reader-to-label">to</span>
            <span>{toList}</span>
          </div>
        </header>

        <ReaderBody
          format={effectiveFormat}
          html={messageBodyHtml}
          plain={messageBodyPlain}
          folder={folder}
          messageId={envelopeId}
          seen={seen}
          setMessage={setMessage}
          matchTheme={matchTheme && effectiveFormat === 'rich'}
        />

        <Attachments
          attachments={attachments}
          onDownload={downloadAttachment}
        />
      </div>

      <ViewSourceModal
        open={sourceOpen}
        subject={sourceSubject}
        rawText={rawText}
        loading={rawLoading}
        error={rawError}
        onClose={closeSource}
        initialTab={sourceInitialTab}
      />
    </div>
  );
}

export default MessageOverlay;
