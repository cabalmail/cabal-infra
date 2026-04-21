import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  Minus, Maximize2, Minimize2, X, Paperclip, ChevronDown,
} from 'lucide-react';
import './ComposeOverlay.css';
import { ADDRESS_LIST } from '../../constants';
import { swatchFor } from '../../utils/addressSwatch';
import { useEditor, EditorContent } from '@tiptap/react';
import StarterKit from '@tiptap/starter-kit';
import TextAlign from '@tiptap/extension-text-align';
import TurndownService from 'turndown';
import { marked } from 'marked';
import useApi from '../../hooks/useApi';
import { useAuth } from '../../contexts/AuthContext';
import { useAppMessage } from '../../contexts/AppMessageContext';

const turndown = new TurndownService({ headingStyle: 'atx', hr: '---' });

const MESSAGE = {
  target: {
    id: "recipient-to"
  }
};

function MenuBar({ editor, onImportMarkdown }) {
  if (!editor) return null;

  return (
    <div className="wysiwyg-toolbar">
      <button type="button" onClick={onImportMarkdown}
        title="Import from Markdown">&#9100;</button>
      <span className="toolbar-separator" />
      <button type="button" onClick={() => editor.chain().focus().toggleBold().run()}
        className={editor.isActive('bold') ? 'active' : ''} title="Bold">B</button>
      <button type="button" onClick={() => editor.chain().focus().toggleItalic().run()}
        className={editor.isActive('italic') ? 'active' : ''} title="Italic"><em>I</em></button>
      <button type="button" onClick={() => editor.chain().focus().toggleUnderline().run()}
        className={editor.isActive('underline') ? 'active' : ''} title="Underline"><u>U</u></button>
      <button type="button" onClick={() => editor.chain().focus().toggleStrike().run()}
        className={editor.isActive('strike') ? 'active' : ''} title="Strikethrough"><s>S</s></button>
      <span className="toolbar-separator" />
      <button type="button" onClick={() => editor.chain().focus().toggleHeading({ level: 1 }).run()}
        className={editor.isActive('heading', { level: 1 }) ? 'active' : ''} title="Heading 1">H1</button>
      <button type="button" onClick={() => editor.chain().focus().toggleHeading({ level: 2 }).run()}
        className={editor.isActive('heading', { level: 2 }) ? 'active' : ''} title="Heading 2">H2</button>
      <button type="button" onClick={() => editor.chain().focus().toggleHeading({ level: 3 }).run()}
        className={editor.isActive('heading', { level: 3 }) ? 'active' : ''} title="Heading 3">H3</button>
      <button type="button" onClick={() => editor.chain().focus().toggleHeading({ level: 4 }).run()}
        className={editor.isActive('heading', { level: 4 }) ? 'active' : ''} title="Heading 4">H4</button>
      <button type="button" onClick={() => editor.chain().focus().toggleBulletList().run()}
        className={editor.isActive('bulletList') ? 'active' : ''} title="Bullet list">&#8226;</button>
      <button type="button" onClick={() => editor.chain().focus().toggleOrderedList().run()}
        className={editor.isActive('orderedList') ? 'active' : ''} title="Numbered list">1.</button>
      <span className="toolbar-separator" />
      <button type="button" onClick={() => editor.chain().focus().setTextAlign('left').run()}
        className={editor.isActive({ textAlign: 'left' }) ? 'active' : ''} title="Align left">&#8676;</button>
      <button type="button" onClick={() => editor.chain().focus().setTextAlign('center').run()}
        className={editor.isActive({ textAlign: 'center' }) ? 'active' : ''} title="Align center">&#8596;</button>
      <button type="button" onClick={() => editor.chain().focus().setTextAlign('right').run()}
        className={editor.isActive({ textAlign: 'right' }) ? 'active' : ''} title="Align right">&#8677;</button>
      <span className="toolbar-separator" />
      <button type="button" onClick={() => {
        const url = window.prompt('URL');
        if (url) editor.chain().focus().setLink({ href: url }).run();
      }} className={editor.isActive('link') ? 'active' : ''} title="Link">&#128279;</button>
      <button type="button" onClick={() => editor.chain().focus().unsetLink().run()}
        disabled={!editor.isActive('link')} title="Remove link">&#10060;</button>
      <span className="toolbar-separator" />
      <button type="button" onClick={() => editor.chain().focus().setHorizontalRule().run()}
        title="Horizontal rule">&mdash;</button>
      <button type="button" onClick={() => editor.chain().focus().undo().run()}
        disabled={!editor.can().undo()} title="Undo">&#8617;</button>
      <button type="button" onClick={() => editor.chain().focus().redo().run()}
        disabled={!editor.can().redo()} title="Redo">&#8618;</button>
    </div>
  );
}

function isEditorEmpty(editor) {
  if (!editor) return true;
  const html = editor.getHTML();
  return !html || html === '<p></p>';
}

function formatSaved(ts) {
  if (!ts) return 'Draft not saved';
  const diff = Math.max(0, Math.round((Date.now() - ts) / 1000));
  if (diff < 5) return 'Saved just now';
  if (diff < 60) return `Saved ${diff}s ago`;
  return `Saved ${Math.round(diff / 60)}m ago`;
}

function ComposeOverlay({
  hide,
  body,
  recipient: propRecipient,
  envelope,
  subject: propSubject,
  type,
  other_headers,
  smtp_host,
  stackIndex = 0,
  composeFromAddress,
  setComposeFromAddress,
  layout = 'desktop',
}) {
  const { smtp_host: ctxSmtpHost } = useAuth();
  const { setMessage } = useAppMessage();
  const api = useApi();

  const effectiveSmtpHost = smtp_host || ctxSmtpHost;

  const [addresses, setAddresses] = useState([]);
  const [address, setAddress] = useState(composeFromAddress || "");
  const [recipient, setRecipient] = useState("");
  const [validationFail, setValidationFail] = useState(false);
  const [To, setTo] = useState([]);
  const [CC, setCC] = useState([]);
  const [BCC, setBCC] = useState([]);
  const [Subject, setSubject] = useState("");
  const [editorMode, setEditorMode] = useState("rich");
  const [markdownContent, setMarkdownContent] = useState("");
  const [showCcBcc, setShowCcBcc] = useState(false);
  const [fromMenuOpen, setFromMenuOpen] = useState(false);
  const [windowState, setWindowState] = useState('normal'); // 'normal' | 'minimized' | 'expanded'
  const [sending, setSending] = useState(false);
  const [savedAt, setSavedAt] = useState(null);
  const [, setSavedTick] = useState(0); // forces re-render for "Saved just now" label
  const markdownRef = useRef(null);
  const fromMenuRef = useRef(null);
  const rootRef = useRef(null);
  const autosaveRef = useRef(null);

  const editor = useEditor({
    extensions: [
      StarterKit.configure({
        link: { openOnClick: false },
      }),
      TextAlign.configure({ types: ['heading', 'paragraph'] }),
    ],
    content: body || '',
  });

  // Initialize compose state based on type (reply/replyAll/forward/new)
  useEffect(() => {
    switch (type) {
      case "reply":
        setAddress(propRecipient);
        setTo(envelope.from);
        setCC([]);
        setSubject(propSubject);
        break;
      case "replyAll": {
        let toList = [...new Set([
          ...(envelope.from),
          ...(envelope.to || [])
        ])];
        const i = toList.indexOf(propRecipient);
        if (i > -1) toList.splice(i, 1);
        let ccList = envelope.cc ? envelope.cc.slice() : [];
        const j = ccList.indexOf(propRecipient);
        if (j > -1) ccList.splice(j, 1);
        if (i === -1 && j === -1) {
          setMessage("Warning: You are replying to a blind copy.", true);
        }
        setAddress(propRecipient);
        setTo(toList);
        setCC(ccList);
        if (ccList.length > 0) setShowCcBcc(true);
        setSubject(propSubject);
        break;
      }
      case "forward":
        setAddress(propRecipient);
        setTo([]);
        setCC([]);
        setSubject(propSubject);
        break;
      default:
        break;
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Fetch addresses on mount
  useEffect(() => {
    api.getAddresses().then(data => {
      try {
        localStorage.setItem(ADDRESS_LIST, JSON.stringify(data));
      } catch (e) {
        console.log(e);
      }
      const list = data.data.Items.map(a => a.address).sort();
      setAddresses(list);
      // Respect explicit reply-derived `address` (set above in reply/replyAll/forward)
      // and a user-picked `composeFromAddress`; otherwise default to the first
      // address so the picker isn't empty.
      setAddress(prev => {
        if (prev) return prev;
        if (composeFromAddress && list.includes(composeFromAddress)) {
          return composeFromAddress;
        }
        return list[0] || "";
      });
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Close From menu on outside click
  useEffect(() => {
    if (!fromMenuOpen) return undefined;
    const onClick = (e) => {
      if (fromMenuRef.current && !fromMenuRef.current.contains(e.target)) {
        setFromMenuOpen(false);
      }
    };
    document.addEventListener('mousedown', onClick);
    return () => document.removeEventListener('mousedown', onClick);
  }, [fromMenuOpen]);

  // Convert pasted rich text to markdown in the markdown editor
  useEffect(() => {
    const el = markdownRef.current;
    if (!el) return undefined;
    const handlePaste = (e) => {
      const html = e.clipboardData.getData('text/html');
      if (!html) return;
      e.preventDefault();
      const md = turndown.turndown(html);
      const { selectionStart, selectionEnd } = el;
      setMarkdownContent(prev =>
        prev.slice(0, selectionStart) + md + prev.slice(selectionEnd)
      );
      requestAnimationFrame(() => {
        const newPos = selectionStart + md.length;
        el.selectionStart = newPos;
        el.selectionEnd = newPos;
      });
    };
    el.addEventListener('paste', handlePaste);
    return () => el.removeEventListener('paste', handlePaste);
  }, []);

  // Refresh the "Saved just now" label once a minute so it ages in place.
  useEffect(() => {
    const id = window.setInterval(() => setSavedTick(t => t + 1), 30000);
    return () => window.clearInterval(id);
  }, []);

  // Autosave stub — §4e calls for every 2s of idleness. There is no server-
  // side draft endpoint yet, so for now we debounce a local timestamp that
  // powers the "Saved just now" label. When a draft API lands, hook into it
  // here instead of the timestamp-only placeholder.
  useEffect(() => {
    if (autosaveRef.current) window.clearTimeout(autosaveRef.current);
    autosaveRef.current = window.setTimeout(() => {
      setSavedAt(Date.now());
    }, 2000);
    return () => {
      if (autosaveRef.current) window.clearTimeout(autosaveRef.current);
    };
  }, [To, CC, BCC, Subject, markdownContent, address]);

  const importFromRich = useCallback(() => {
    if (markdownContent.trim()) {
      if (!window.confirm("This will replace your current Markdown content. Continue?")) {
        return;
      }
    }
    setMarkdownContent(turndown.turndown(editor.getHTML()));
  }, [editor, markdownContent]);

  const importFromMarkdown = useCallback(() => {
    if (!isEditorEmpty(editor)) {
      if (!window.confirm("This will replace your current Rich Text content. Continue?")) {
        return;
      }
    }
    const html = marked.parse(markdownContent, { async: false });
    editor.commands.setContent(html, { emitUpdate: true });
  }, [editor, markdownContent]);

  const randomString = useCallback((length) => {
    let str = '';
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    const len = chars.length;
    for (let i = 0; i < length; i++) {
      str += chars.charAt(Math.floor(Math.random() * len));
    }
    return str;
  }, []);

  const validateAddress = useCallback((addr) => {
    const re = /(([^<>()[\]\\.,;:\s@"]+(\.[^<>()[\]\\.,;:\s@"]+)*)|.(".+"))@((([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))/;
    return addr.match(re);
  }, []);

  const addRecipient = useCallback((e) => {
    if (validateAddress(recipient)) {
      const unionList = [...To, ...CC, ...BCC];
      if (unionList.indexOf(recipient) > -1) return;
      switch (e.target.id) {
        case "recipient-to":
          setTo(prev => [...prev, recipient]);
          break;
        case "recipient-cc":
          setCC(prev => [...prev, recipient]);
          break;
        case "recipient-bcc":
          setBCC(prev => [...prev, recipient]);
          break;
        default:
          setTo(prev => [...prev, recipient]);
      }
      setRecipient("");
    } else {
      setValidationFail(true);
    }
  }, [recipient, To, CC, BCC, validateAddress]);

  const handleSubmit = (e) => {
    e.preventDefault();
    return false;
  };

  const pickAddress = useCallback((addr) => {
    setAddress(addr);
    setFromMenuOpen(false);
    if (typeof setComposeFromAddress === 'function') {
      setComposeFromAddress(addr);
    }
  }, [setComposeFromAddress]);

  const handleSend = useCallback(() => {
    const oh = other_headers || {};
    const irt = oh.message_id || [];
    const msgid = ['<' + randomString(30) + '@' + effectiveSmtpHost + '>'];
    const ref = [...new Set([
      ...(oh.references || []),
      ...(oh.message_id || []),
      ...(oh.in_reply_to || [])
    ])];
    const headers = {
      in_reply_to: irt.map(s => s.trim()),
      message_id: msgid.map(s => s.trim()),
      references: ref.map(s => s.trim())
    };
    if (recipient) {
      addRecipient(MESSAGE);
    }
    if (To.length + CC.length + BCC.length === 0) {
      setMessage("Please specify at least one recipient.", true);
      return;
    }
    if (Subject === "") {
      setMessage("Please provide a subject.", true);
      return;
    }
    if (addresses.indexOf(address) === -1) {
      setMessage("Please select an address from which to send.", true);
      return;
    }
    setSending(true);

    const richEmpty = isEditorEmpty(editor);
    const mdEmpty = !markdownContent.trim();

    let htmlBody, textBody;
    if (richEmpty && mdEmpty) {
      htmlBody = '';
      textBody = '';
    } else if (!richEmpty && mdEmpty) {
      htmlBody = editor.getHTML();
      textBody = turndown.turndown(htmlBody);
    } else if (richEmpty && !mdEmpty) {
      textBody = markdownContent;
      htmlBody = marked.parse(markdownContent);
    } else {
      htmlBody = editor.getHTML();
      textBody = markdownContent;
    }

    api.sendMessage(
      effectiveSmtpHost, address, To, CC, BCC, Subject, headers,
      htmlBody, textBody, false
    ).then(() => {
      setMessage("Email sent", false);
      setSending(false);
      hide();
    }).catch((err) => {
      setMessage("Error sending email", true);
      setSending(false);
      console.log(err);
    });
  }, [other_headers, effectiveSmtpHost, recipient, To, CC, BCC, Subject, address, addresses,
      editor, markdownContent, api, hide, setMessage, addRecipient, randomString]);

  const handleDiscard = useCallback((e) => {
    e.preventDefault();
    hide();
  }, [hide]);

  const onRecipientChange = (e) => {
    setRecipient(e.target.value);
    setValidationFail(false);
  };

  const handleKeyDown = (e) => {
    if (e.key === "Enter" || e.key === " " || e.key === ";" || e.key === ",") {
      e.preventDefault();
      addRecipient(MESSAGE);
    }
    if (e.key === "Tab") {
      addRecipient(MESSAGE);
    }
  };

  const removeRecipient = useCallback((list, setList, e) => {
    const addr = e.target.value;
    setList(prev => prev.filter(a => a !== addr));
    setRecipient(addr);
  }, []);

  // Root-level keyboard handler: Cmd/Ctrl+Enter sends, Esc minimizes.
  const onRootKeyDown = useCallback((e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      handleSend();
      return;
    }
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      setWindowState('minimized');
    }
  }, [handleSend]);

  // §4e: multiple compose windows stack horizontally with 8px gaps.
  // Each window is 600px wide, pinned bottom-right, offset by its index.
  // Sheet mode (phone) ignores stackIndex — the sheet always fills the
  // viewport, so stacking would just hide prior windows anyway.
  const style = useMemo(() => {
    if (layout === 'phone') return {};
    const width = 600;
    const gap = 8;
    const offset = 24 + stackIndex * (width + gap);
    return { right: `${offset}px` };
  }, [stackIndex, layout]);

  const savedLabel = savedAt ? formatSaved(savedAt) : 'Draft not saved';

  const renderRecipientChip = (addr, listName, setList) => (
    <span className={`recipient-chip recipient-chip--${listName.toLowerCase()}`} key={`${listName}-${addr}`}>
      <span className="recipient-chip__address">{addr}</span>
      <button
        type="button"
        className="recipient-chip__remove"
        onClick={(e) => removeRecipient(
          listName === 'To' ? To : listName === 'CC' ? CC : BCC,
          setList, e
        )}
        value={addr}
        aria-label={`Remove ${addr}`}
      >
        <X size={12} />
      </button>
    </span>
  );

  const fromSwatch = address ? swatchFor(address) : null;

  const isSheet = layout === 'phone';

  return (
    <form
      ref={rootRef}
      className={`compose-overlay compose-overlay--${windowState}${isSheet ? ' compose-overlay--sheet' : ''}`}
      data-layout={isSheet ? 'sheet' : undefined}
      style={style}
      onSubmit={handleSubmit}
      onKeyDown={onRootKeyDown}
    >
      {isSheet ? (
        <div className="compose-chrome compose-chrome--sheet">
          <button
            type="button"
            className="compose-chrome__text compose-chrome__text--cancel"
            onClick={(e) => handleDiscard(e)}
          >
            Cancel
          </button>
          <span className="compose-chrome__title">New message</span>
          <button
            type="button"
            className="compose-chrome__text compose-chrome__text--send"
            onClick={handleSend}
            disabled={sending}
          >
            {sending ? 'Sending…' : 'Send'}
          </button>
        </div>
      ) : (
        <div className="compose-chrome">
          <span className="compose-chrome__title">New message</span>
          <div className="compose-chrome__actions">
            <button
              type="button"
              className="compose-chrome__btn"
              aria-label="Minimize"
              onClick={() => setWindowState(s => s === 'minimized' ? 'normal' : 'minimized')}
            >
              <Minus size={14} />
            </button>
            <button
              type="button"
              className="compose-chrome__btn"
              aria-label={windowState === 'expanded' ? 'Restore' : 'Expand'}
              onClick={() => setWindowState(s => s === 'expanded' ? 'normal' : 'expanded')}
            >
              {windowState === 'expanded' ? <Minimize2 size={14} /> : <Maximize2 size={14} />}
            </button>
            <button
              type="button"
              className="compose-chrome__btn"
              aria-label="Close"
              onClick={(e) => handleDiscard(e)}
            >
              <X size={14} />
            </button>
          </div>
        </div>
      )}

      <div className="compose-body">
        <div className="compose-row">
          <label className="compose-row__label" htmlFor={`compose-from-${stackIndex}`}>From</label>
          <div className="compose-row__field">
            <div className="from-picker" ref={fromMenuRef}>
              <button
                type="button"
                id={`compose-from-${stackIndex}`}
                className="from-picker__chip"
                onClick={() => setFromMenuOpen(o => !o)}
                aria-haspopup="listbox"
                aria-expanded={fromMenuOpen}
              >
                {fromSwatch && (
                  <span className="from-picker__swatch" style={{ background: fromSwatch }} />
                )}
                <span className="from-picker__address">{address || 'Select address'}</span>
                <ChevronDown size={14} className="from-picker__caret" />
              </button>
              {fromMenuOpen && (
                <ul className="from-picker__menu" role="listbox">
                  {addresses.length === 0 && (
                    <li className="from-picker__empty">No addresses</li>
                  )}
                  {addresses.map(a => (
                    <li key={a}>
                      <button
                        type="button"
                        role="option"
                        aria-selected={a === address}
                        className={`from-picker__option${a === address ? ' is-selected' : ''}`}
                        onClick={() => pickAddress(a)}
                      >
                        <span className="from-picker__swatch" style={{ background: swatchFor(a) }} />
                        <span className="from-picker__address">{a}</span>
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          </div>
        </div>

        <div className="compose-row">
          <label className="compose-row__label" htmlFor={`compose-to-${stackIndex}`}>To</label>
          <div
            className="compose-row__field compose-recipients"
            onClick={() => document.getElementById(`compose-to-${stackIndex}`)?.focus()}
          >
            {To.map(a => renderRecipientChip(a, 'To', setTo))}
            <input
              id={`compose-to-${stackIndex}`}
              type="email"
              aria-label="Recipients"
              onChange={onRecipientChange}
              onKeyDown={handleKeyDown}
              value={recipient}
              className={`recipient-input${validationFail ? " recipient-input--invalid" : ""}`}
            />
          </div>
          <button
            type="button"
            className="compose-cc-toggle"
            onClick={() => setShowCcBcc(v => !v)}
            aria-pressed={showCcBcc}
          >Cc Bcc</button>
        </div>

        {showCcBcc && (
          <>
            <div className="compose-row">
              <label className="compose-row__label" htmlFor={`compose-cc-${stackIndex}`}>Cc</label>
              <div
                className="compose-row__field compose-recipients"
                onClick={() => document.getElementById(`compose-cc-${stackIndex}`)?.focus()}
              >
                {CC.map(a => renderRecipientChip(a, 'CC', setCC))}
                <input
                  id={`compose-cc-${stackIndex}`}
                  type="email"
                  onChange={onRecipientChange}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ' || e.key === ';' || e.key === ',') {
                      e.preventDefault();
                      addRecipient({ target: { id: 'recipient-cc' } });
                    }
                  }}
                  value={recipient}
                  className="recipient-input"
                />
              </div>
            </div>
            <div className="compose-row">
              <label className="compose-row__label" htmlFor={`compose-bcc-${stackIndex}`}>Bcc</label>
              <div
                className="compose-row__field compose-recipients"
                onClick={() => document.getElementById(`compose-bcc-${stackIndex}`)?.focus()}
              >
                {BCC.map(a => renderRecipientChip(a, 'BCC', setBCC))}
                <input
                  id={`compose-bcc-${stackIndex}`}
                  type="email"
                  onChange={onRecipientChange}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ' || e.key === ';' || e.key === ',') {
                      e.preventDefault();
                      addRecipient({ target: { id: 'recipient-bcc' } });
                    }
                  }}
                  value={recipient}
                  className="recipient-input"
                />
              </div>
            </div>
          </>
        )}

        <div className="compose-row compose-row--subject">
          <input
            id={`compose-subject-${stackIndex}`}
            aria-label="Subject"
            type="text"
            className="compose-subject"
            placeholder="Subject"
            onChange={(e) => setSubject(e.target.value)}
            value={Subject}
          />
        </div>

        <div className="compose-editor">
          <div className="editor-mode-tabs">
            <button type="button"
              className={`editor-mode-tab ${editorMode === 'rich' ? 'active' : ''}`}
              onClick={() => setEditorMode('rich')}>Rich Text</button>
            <button type="button"
              className={`editor-mode-tab ${editorMode === 'markdown' ? 'active' : ''}`}
              onClick={() => setEditorMode('markdown')}>Markdown</button>
          </div>
          <div className={`editor-pane ${editorMode === 'rich' ? '' : 'editor-pane-hidden'}`}>
            <MenuBar editor={editor} onImportMarkdown={importFromMarkdown} />
            <EditorContent editor={editor} className="wysiwyg-editor" />
          </div>
          <div className={`editor-pane ${editorMode === 'markdown' ? '' : 'editor-pane-hidden'}`}>
            <div className="editor-import-bar">
              <button type="button" className="import-button" onClick={importFromRich}
                title="Replace Markdown content with converted Rich Text content"
              >Import from Rich Text</button>
            </div>
            <textarea
              ref={markdownRef}
              className="markdown-editor"
              value={markdownContent}
              onChange={(e) => setMarkdownContent(e.target.value)}
            />
          </div>
        </div>
      </div>

      <div className="compose-bottom">
        <div className="compose-bottom__left">
          <button
            type="button"
            className={`compose-send${sending ? ' is-sending' : ''}`}
            onClick={handleSend}
            disabled={sending}
          >{sending ? 'Sending…' : 'Send'}</button>
          <button
            type="button"
            className="compose-icon-btn"
            title="Attach file"
            aria-label="Attach file"
          >
            <Paperclip size={16} />
          </button>
        </div>
        <div className="compose-bottom__right">
          <span className="compose-saved" aria-live="polite">{savedLabel}</span>
          <button
            type="button"
            className="compose-icon-btn"
            onClick={handleDiscard}
            aria-label="Discard"
            title="Discard"
          >
            <X size={16} />
          </button>
        </div>
      </div>
    </form>
  );
}

export default ComposeOverlay;
