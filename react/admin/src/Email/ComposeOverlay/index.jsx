import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  Minus, Maximize2, Minimize2, X, Paperclip,
} from 'lucide-react';
import './ComposeOverlay.css';
import { ADDRESS_LIST, ANSWERED } from '../../constants';
import { useEditor, EditorContent } from '@tiptap/react';
import StarterKit from '@tiptap/starter-kit';
import TextAlign from '@tiptap/extension-text-align';
import { Fragment, Slice } from '@tiptap/pm/model';
import TurndownService from 'turndown';
import { marked } from 'marked';
import useApi from '../../hooks/useApi';
import { useAuth } from '../../contexts/AuthContext';
import { useAppMessage } from '../../contexts/AppMessageContext';
import ConfirmDialog from '../../ConfirmDialog';
import FromPicker from './FromPicker';
import { extractEmail } from '../../utils/formatDate';

const turndown = new TurndownService({ headingStyle: 'atx', hr: '---' });

// Round-trip with the editor: Enter inserts a hard break (<br>), not a new
// paragraph, so a single newline in Markdown maps to a single newline in HTML.
// Override turndown's defaults — which would otherwise wrap each <p> in blank
// lines and emit two-space-newline for <br> — to keep paragraphs single-spaced
// and <br>s as plain newlines.
//
// The leading ​ (zero-width space) is a placeholder: turndown's internal
// join() collapses adjacent newlines to the longer of (trailing-of-prev,
// leading-of-next), so two <br>s each emitting plain "\n" would collapse to
// a single "\n". Prefixing the newline with a non-newline character hides it
// from the leading-newline detection so consecutive line breaks accumulate.
// htmlToMarkdown() strips the placeholders before returning.
turndown.addRule('paragraph', {
  filter: 'p',
  replacement: (content) => `${content}\u200B\n`,
});
turndown.addRule('lineBreak', {
  filter: 'br',
  replacement: () => '\u200B\n',
});

function htmlToMarkdown(html) {
  return turndown.turndown(html).replace(/\u200B/g, '');
}

const MESSAGE = {
  target: {
    id: "recipient-to"
  }
};

const ADDRESS_RE = /(([^<>()[\]\\.,;:\s@"]+(\.[^<>()[\]\\.,;:\s@"]+)*)|.(".+"))@((([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))/;

function isValidAddress(addr) {
  return addr.match(ADDRESS_RE);
}

// Fold text still sitting in the recipient input into the recipient lists.
// The To/Cc/Bcc rows share one input state, so uncommitted text belongs to
// whichever row it was typed in — `fieldId` names that row. Returns the
// lists as they read once the text is committed, which is what Send has to
// validate and ship: the click that fires Send also flushes the pending
// text, but that setState has not landed yet, so the To/CC/BCC it closes
// over still read pre-flush.
function withPendingRecipient(lists, pending, fieldId) {
  if (!pending || !isValidAddress(pending)) return lists;
  if ([...lists.to, ...lists.cc, ...lists.bcc].indexOf(pending) > -1) return lists;
  switch (fieldId) {
    case "recipient-cc":
      return { ...lists, cc: [...lists.cc, pending] };
    case "recipient-bcc":
      return { ...lists, bcc: [...lists.bcc, pending] };
    default:
      return { ...lists, to: [...lists.to, pending] };
  }
}

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
  if (typeof editor.isEmpty === 'boolean') return editor.isEmpty;
  // Fallback: match either the vanilla or the paragraph-style-wrapped empty
  // shape. Older TipTap builds (or a mocked editor in tests) may not surface
  // the isEmpty property.
  const html = editor.getHTML();
  if (!html) return true;
  return html === '<p></p>' || /^<p\s+style="[^"]*"><\/p>$/.test(html);
}

// Mirror the editor's tight paragraph spacing on the wire so the recipient's
// mail client doesn't fall back to its default <p> margin (typically ~1em).
// Skips paragraphs that already carry a style attribute.
function styleParagraphs(html) {
  return html.replace(/<p(\s[^>]*)?>/g, (match, attrs) => {
    if (attrs && /\sstyle\s*=/i.test(attrs)) return match;
    return `<p${attrs || ''} style="margin:0">`;
  });
}

// marked emits a fresh <p> for every blank-line-delimited block. The editor
// uses Enter = hard break, so author intent is one continuous paragraph with
// <br>s. Collapse each </p>…<p> boundary to <br><br> so blank lines in the
// Markdown side become explicit empty visual lines in the HTML side instead
// of an extra-spaced paragraph break.
function flattenParagraphs(html) {
  return html.replace(/<\/p>\s*<p[^>]*>/g, '<br><br>');
}

function markdownToHtml(md) {
  return flattenParagraphs(marked.parse(md, { breaks: true, async: false }));
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
  forward_attachments,
  reply_source,
  smtp_host,
  domains: propDomains,
  stackIndex = 0,
  composeFromAddress,
  setComposeFromAddress,
  layout = 'desktop',
}) {
  const { smtp_host: ctxSmtpHost, domains: ctxDomains } = useAuth();
  const { setMessage } = useAppMessage();
  const api = useApi();

  const effectiveSmtpHost = smtp_host || ctxSmtpHost;
  const effectiveDomains = propDomains || ctxDomains || [];

  const [addressItems, setAddressItems] = useState([]);
  const [address, setAddress] = useState(composeFromAddress || "");
  const [recipient, setRecipient] = useState("");
  // Which row the shared recipient input is currently being typed into, so
  // Send commits pending text back to that row rather than assuming To.
  const [recipientField, setRecipientField] = useState("recipient-to");
  const [validationFail, setValidationFail] = useState(false);
  const [To, setTo] = useState([]);
  const [CC, setCC] = useState([]);
  const [BCC, setBCC] = useState([]);
  const [Subject, setSubject] = useState("");
  const [editorMode, setEditorMode] = useState("rich");
  const [markdownContent, setMarkdownContent] = useState("");
  const [showCcBcc, setShowCcBcc] = useState(false);
  const [windowState, setWindowState] = useState('normal'); // 'normal' | 'minimized' | 'expanded'
  const [sending, setSending] = useState(false);
  // savedAt flips to a real timestamp only after a successful /save_draft
  // round-trip; the "Saved just now" label is truthful (never set on a
  // freshly opened, un-typed compose).
  const [savedAt, setSavedAt] = useState(null);
  const [, setSavedTick] = useState(0); // forces re-render for "Saved just now" label
  const [editorRevision, setEditorRevision] = useState(0); // bumped by editor.onUpdate
  const [pendingImport, setPendingImport] = useState(null); // 'fromRich' | 'fromMarkdown' | null
  const [pendingDiscard, setPendingDiscard] = useState(false);
  const [attachments, setAttachments] = useState([]); // [{ id, filename, mimeType, file (Blob), size }]
  const markdownRef = useRef(null);
  const rootRef = useRef(null);
  const autosaveRef = useRef(null);
  const fileInputRef = useRef(null);
  // Server draft state: coordinates of the current Drafts copy (from the
  // last successful /save_draft APPENDUID). Passed as replaces_* on the
  // next save, and as discard_draft_* on /send so the stale copy is
  // expunged after delivery.
  const draftCoordsRef = useRef(null);
  const saveInFlightRef = useRef(false);
  // dirty = content has changed since the last successful server save.
  // Guards the autosave debounce against no-op saves and lets the
  // close-without-send handler decide whether to flush.
  const dirtyRef = useRef(false);
  // Debounce interval before the autosave fires. Small enough that a
  // typing pause captures the draft on the server; not so small that
  // heavy typing floods IMAP appends.
  const AUTOSAVE_DEBOUNCE_MS = 3000;

  const addresses = useMemo(
    () => addressItems.map((a) => a.address),
    [addressItems]
  );

  const editor = useEditor({
    extensions: [
      StarterKit.configure({
        link: { openOnClick: false },
        paragraph: { HTMLAttributes: { style: 'margin:0' } },
      }),
      TextAlign.configure({ types: ['heading', 'paragraph'] }),
    ],
    editorProps: {
      // Enter = hard break in plain paragraphs, so the document is one
      // long flow of <br>-separated lines rather than a stack of <p>s.
      // Lists, code blocks, and headings keep their default Enter handling
      // (new list item / literal newline / exit-to-paragraph).
      handleKeyDown: (view, event) => {
        if (event.key !== 'Enter' || event.shiftKey || event.metaKey || event.ctrlKey) {
          return false;
        }
        const { $from } = view.state.selection;
        for (let depth = $from.depth; depth >= 0; depth--) {
          const name = $from.node(depth).type.name;
          if (name === 'listItem' || name === 'taskItem' || name === 'codeBlock' || name === 'heading') {
            return false;
          }
        }
        const { hardBreak } = view.state.schema.nodes;
        if (!hardBreak) return false;
        view.dispatch(view.state.tr.replaceSelectionWith(hardBreak.create()).scrollIntoView());
        return true;
      },
      // HTML paste: collapse </p>…<p> boundaries before TipTap parses, so
      // pasted multi-paragraph blocks land as a single paragraph with
      // <br><br>s — same shape as Enter-typed content.
      transformPastedHTML: (html) => flattenParagraphs(html),
      // Plain-text paste: by default ProseMirror creates one paragraph per
      // newline-delimited line. Replace that with a single inline run of
      // text + hardBreaks so each \n becomes one <br>, matching Enter.
      clipboardTextParser: (text, _$context, _plain, view) => {
        const { schema } = view.state;
        const { hardBreak, paragraph } = schema.nodes;
        if (!hardBreak || !paragraph) return Slice.empty;
        const lines = text.split(/\r\n?|\n/);
        const nodes = [];
        lines.forEach((line, i) => {
          if (line.length > 0) nodes.push(schema.text(line));
          if (i < lines.length - 1) nodes.push(hardBreak.create());
        });
        if (nodes.length === 0) return Slice.empty;
        // openStart/openEnd = 1 leaves the wrapping paragraph open at both
        // sides so its inline content merges into the surrounding paragraph
        // at the cursor instead of inserting a fresh block.
        const para = paragraph.create(null, Fragment.fromArray(nodes));
        return new Slice(Fragment.from(para), 1, 1);
      },
    },
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
        // Self-removal compares by bare email since list entries may carry
        // a display-name wrapper (`"Name" <addr@host>`) while propRecipient
        // is always a bare address.
        const myEmail = (extractEmail(propRecipient) || propRecipient || '').toLowerCase();
        const matchesSelf = (s) => (extractEmail(s) || s || '').toLowerCase() === myEmail;
        let toList = [...new Set([
          ...(envelope.from),
          ...(envelope.to || [])
        ])];
        const i = toList.findIndex(matchesSelf);
        if (i > -1) toList.splice(i, 1);
        let ccList = envelope.cc ? envelope.cc.slice() : [];
        const j = ccList.findIndex(matchesSelf);
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

  // Forwarding includes the original message's attachments. Seed a chip per
  // attachment right away (marked pending, from the metadata the reader had
  // already loaded), then fetch each one's bytes — /fetch_attachment mints a
  // presigned GET URL — and swap the Blob in. A chip can be removed while
  // still pending; the late-arriving Blob then finds no row and is dropped.
  useEffect(() => {
    if (type !== 'forward') return;
    const src = forward_attachments;
    if (!src || !Array.isArray(src.attachments) || src.attachments.length === 0) return;
    const seeded = src.attachments.map((a) => ({
      id: `fwd-${src.id}-${a.id}`,
      filename: a.name,
      mimeType: a.type || 'application/octet-stream',
      file: null,
      size: a.size || 0,
      pending: true,
    }));
    setAttachments(prev => [...prev, ...seeded]);
    src.attachments.forEach((a, i) => {
      api.getAttachment(a, src.folder, src.id, src.seen)
        .then((data) => api.downloadAttachment(data.data.url))
        .then((resp) => {
          setAttachments(prev => prev.map(x => (x.id === seeded[i].id
            ? {
              ...x, file: resp.data, size: resp.data.size || x.size, pending: false,
            }
            : x)));
        })
        .catch((err) => {
          console.log(err);
          setAttachments(prev => prev.filter(x => x.id !== seeded[i].id));
          setMessage(`Couldn't carry over attachment "${a.name}" from the original message.`, true);
        });
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const loadAddresses = useCallback(() => (
    api.getAddresses().then(data => {
      try {
        localStorage.setItem(ADDRESS_LIST, JSON.stringify(data));
      } catch (e) {
        console.log(e);
      }
      const items = (data?.data?.Items || [])
        .slice()
        .sort((a, b) => (a.address > b.address ? 1 : a.address < b.address ? -1 : 0));
      setAddressItems(items);
      return items;
    })
  ), [api]);

  // Fetch addresses on mount
  useEffect(() => {
    loadAddresses().then((items) => {
      const list = items.map((a) => a.address);
      // Respect explicit reply-derived `address` (set above in reply/replyAll/forward)
      // and a user-picked `composeFromAddress`. Otherwise the From picker stays
      // empty — the user must explicitly choose (or create) a From address
      // before Send is allowed.
      setAddress(prev => {
        if (prev) return prev;
        if (composeFromAddress && list.includes(composeFromAddress)) {
          return composeFromAddress;
        }
        return "";
      });
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Convert pasted rich text to markdown in the markdown editor
  useEffect(() => {
    const el = markdownRef.current;
    if (!el) return undefined;
    const handlePaste = (e) => {
      const html = e.clipboardData.getData('text/html');
      if (!html) return;
      e.preventDefault();
      const md = htmlToMarkdown(html);
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

  // The tiptap editor manages its own state, so state-driven effects don't
  // see typing in the body. Bump a revision counter on every editor update
  // so the autosave debounce and the isEditorEmpty gate re-evaluate.
  useEffect(() => {
    if (!editor) return undefined;
    const handler = () => setEditorRevision((r) => r + 1);
    editor.on('update', handler);
    return () => {
      editor.off('update', handler);
    };
  }, [editor]);

  const hasContent = useCallback(() => {
    if (Subject.trim()) return true;
    if (To.length > 0 || CC.length > 0 || BCC.length > 0) return true;
    if (markdownContent.trim()) return true;
    if (editor && !isEditorEmpty(editor)) return true;
    return false;
  // editorRevision drives editor-content changes since isEditorEmpty is not
  // otherwise reactive.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [Subject, To, CC, BCC, markdownContent, editor, editorRevision]);

  // Same body-shape derivation handleSend uses: pick from tiptap HTML and
  // the markdown textarea, prefer whichever pane has content, and produce
  // both halves for the multipart/alternative MIME.
  const buildComposeBodies = useCallback(() => {
    const richEmpty = isEditorEmpty(editor);
    const mdEmpty = !markdownContent.trim();
    let htmlBody;
    let textBody;
    if (richEmpty && mdEmpty) {
      htmlBody = '';
      textBody = '';
    } else if (!richEmpty && mdEmpty) {
      htmlBody = editor.getHTML();
      textBody = htmlToMarkdown(htmlBody);
    } else if (richEmpty && !mdEmpty) {
      textBody = markdownContent;
      htmlBody = styleParagraphs(markdownToHtml(markdownContent));
    } else {
      htmlBody = editor.getHTML();
      textBody = markdownContent;
    }
    return { htmlBody, textBody };
  }, [editor, markdownContent]);

  const buildComposeHeaders = useCallback(() => {
    const oh = other_headers || {};
    const irt = (oh.in_reply_to || []).map((s) => s.trim());
    const mid = (oh.message_id || []).map((s) => s.trim());
    const ref = [...new Set([
      ...(oh.references || []),
      ...(oh.message_id || []),
      ...(oh.in_reply_to || []),
    ])].map((s) => s.trim());
    return { in_reply_to: irt, message_id: mid, references: ref };
  }, [other_headers]);

  // Save the current compose state to the server-side Drafts folder via
  // /save_draft. Fire-and-forget: the caller doesn't await unless it wants
  // to flush before close. Skipped when a prior save is in flight, when a
  // send is running, when there is nothing to save, or when no From address
  // has been picked (/save_draft rejects unauthorized senders).
  //
  // Attachments are deliberately omitted from draft saves: /send still
  // uploads and includes them, but replaying an S3 upload on every debounce
  // would re-charge bandwidth for large files. See PR notes for the trade-
  // off; the React UI does not yet offer an "Edit Draft" flow that would
  // surface the omission.
  const performServerSave = useCallback(async () => {
    if (saveInFlightRef.current) return;
    if (sending) return;
    if (!hasContent()) return;
    if (!address) return;
    const { htmlBody, textBody } = buildComposeBodies();
    const headers = buildComposeHeaders();
    saveInFlightRef.current = true;
    try {
      const resp = await api.saveDraft({
        sender: address,
        to_list: To,
        cc_list: CC,
        bcc_list: BCC,
        subject: Subject,
        other_headers: headers,
        html_body: htmlBody,
        text_body: textBody,
        attachments: [],
        op: 'save',
        replaces: draftCoordsRef.current,
      });
      const data = (resp && resp.data) || {};
      if (data.uid != null && data.uidvalidity != null) {
        draftCoordsRef.current = { uid: data.uid, uidvalidity: data.uidvalidity };
      }
      setSavedAt(Date.now());
      dirtyRef.current = false;
    } catch (err) {
      // Leave dirtyRef true so the next debounce or close-flush retries.
      console.log('draft save failed', err);
    } finally {
      saveInFlightRef.current = false;
    }
  }, [sending, hasContent, address, To, CC, BCC, Subject, buildComposeBodies, buildComposeHeaders, api]);

  // Autosave: debounce a server /save_draft after any change to a compose
  // field or editor content. The effect fires on mount too (initial deps),
  // but performServerSave's gates make that a no-op for empty composes.
  useEffect(() => {
    dirtyRef.current = true;
    if (autosaveRef.current) window.clearTimeout(autosaveRef.current);
    autosaveRef.current = window.setTimeout(() => {
      performServerSave();
    }, AUTOSAVE_DEBOUNCE_MS);
    return () => {
      if (autosaveRef.current) window.clearTimeout(autosaveRef.current);
    };
  }, [To, CC, BCC, Subject, markdownContent, address, editorRevision, performServerSave]);

  const performImportFromRich = useCallback(() => {
    setMarkdownContent(htmlToMarkdown(editor.getHTML()));
  }, [editor]);

  const performImportFromMarkdown = useCallback(() => {
    editor.commands.setContent(markdownToHtml(markdownContent), { emitUpdate: true });
  }, [editor, markdownContent]);

  const importFromRich = useCallback(() => {
    if (markdownContent.trim()) {
      setPendingImport('fromRich');
      return;
    }
    performImportFromRich();
  }, [markdownContent, performImportFromRich]);

  const importFromMarkdown = useCallback(() => {
    if (!isEditorEmpty(editor)) {
      setPendingImport('fromMarkdown');
      return;
    }
    performImportFromMarkdown();
  }, [editor, performImportFromMarkdown]);

  const cancelImport = useCallback(() => {
    setPendingImport(null);
  }, []);

  const confirmImport = useCallback(() => {
    const which = pendingImport;
    setPendingImport(null);
    if (which === 'fromRich') performImportFromRich();
    else if (which === 'fromMarkdown') performImportFromMarkdown();
  }, [pendingImport, performImportFromRich, performImportFromMarkdown]);

  const randomString = useCallback((length) => {
    let str = '';
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    const len = chars.length;
    for (let i = 0; i < length; i++) {
      str += chars.charAt(Math.floor(Math.random() * len));
    }
    return str;
  }, []);

  const addRecipient = useCallback((e) => {
    if (!isValidAddress(recipient)) {
      setValidationFail(true);
      return;
    }
    if ([...To, ...CC, ...BCC].indexOf(recipient) > -1) return;
    const next = withPendingRecipient({ to: To, cc: CC, bcc: BCC }, recipient, e.target.id);
    setTo(next.to);
    setCC(next.cc);
    setBCC(next.bcc);
    setRecipient("");
  }, [recipient, To, CC, BCC]);

  const handleSubmit = (e) => {
    e.preventDefault();
    return false;
  };

  const pickAddress = useCallback((addr) => {
    setAddress(addr);
    if (typeof setComposeFromAddress === 'function') {
      setComposeFromAddress(addr);
    }
  }, [setComposeFromAddress]);

  const onAddressCreated = useCallback(() => {
    // The create call invalidates the ADDRESS_LIST cache via ApiClient.newAddress;
    // re-fetch so the newly-created row (with its comment/label) surfaces in the
    // picker immediately.
    loadAddresses().catch(() => { /* non-fatal */ });
  }, [loadAddresses]);

  // A reply that has actually left flags the message it answers, so the
  // replied indicator every client renders (React's reply icon, the Apple
  // message list) reflects the mailbox rather than which client was used.
  // Fire-and-forget on the success path: the mail is already away, and a
  // failed flag costs an indicator, not a message.
  const markSourceAnswered = useCallback(() => {
    if (type !== "reply" && type !== "replyAll") return;
    const { folder: srcFolder, id: srcId } = reply_source || {};
    if (!srcFolder || !srcId) return;
    api.setFlag(srcFolder, ANSWERED.imap, ANSWERED.op, [srcId])
      .catch((err) => console.log(err));
  }, [api, type, reply_source]);

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
    // Validate and send the lists as they read with the pending input text
    // folded in — committing it through addRecipient below only updates the
    // chips on the next render, one step too late for this click.
    const { to: sendTo, cc: sendCc, bcc: sendBcc } =
      withPendingRecipient({ to: To, cc: CC, bcc: BCC }, recipient, recipientField);
    if (recipient) {
      addRecipient({ target: { id: recipientField } });
    }
    if (sendTo.length + sendCc.length + sendBcc.length === 0) {
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
    if (attachments.some(a => a.pending)) {
      setMessage("Attachments are still loading — please wait a moment.", true);
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
      textBody = htmlToMarkdown(htmlBody);
    } else if (richEmpty && !mdEmpty) {
      textBody = markdownContent;
      htmlBody = styleParagraphs(markdownToHtml(markdownContent));
    } else {
      htmlBody = editor.getHTML();
      textBody = markdownContent;
    }

    // Upload any attachments directly to S3 first, then send the message
    // referencing them by key. Bypasses API Gateway's 10 MB request ceiling.
    const uploadAndSend = async () => {
      let wireAttachments = [];
      if (attachments.length > 0) {
        const resp = await api.getAttachmentUploadUrls(attachments);
        const uploads = resp?.data?.uploads || [];
        if (uploads.length !== attachments.length) {
          throw new Error('upload_url returned the wrong number of slots');
        }
        await Promise.all(attachments.map((a, i) =>
          api.uploadAttachmentToS3(uploads[i].url, a.file)
        ));
        wireAttachments = attachments.map((a, i) => ({
          filename: a.filename,
          mime_type: a.mimeType,
          s3_key: uploads[i].key,
        }));
      }
      await api.sendMessage(
        effectiveSmtpHost, address, sendTo, sendCc, sendBcc, Subject, headers,
        htmlBody, textBody, false, wireAttachments,
        // If autosave wrote a Drafts copy, ask /send to expunge it after
        // successful delivery so the stale draft doesn't linger. Best
        // effort server-side; a miss becomes a manual cleanup, not a lost
        // send.
        draftCoordsRef.current
      );
    };

    uploadAndSend().then(() => {
      markSourceAnswered();
      setMessage("Email sent", false);
      setSending(false);
      hide();
    }).catch((err) => {
      setMessage("Error sending email", true);
      setSending(false);
      console.log(err);
    });
  }, [other_headers, effectiveSmtpHost, recipient, recipientField, To, CC, BCC, Subject, address, addresses,
      editor, markdownContent, attachments, api, hide, setMessage, addRecipient, randomString,
      markSourceAnswered]);

  // Close-without-send: match the Apple compose flow and always attempt a
  // final /save_draft (fire-and-forget) so the draft survives the closing
  // overlay. Empty / unauthenticated / in-flight composes fall through to
  // performServerSave's gates and just hide.
  //
  // Special case: content typed before a From address is picked cannot be
  // autosaved (/save_draft rejects unauthorized senders), so a silent close
  // would drop it. Intercept that path with a confirm dialog — the user
  // either goes back and picks a From, or explicitly discards.
  const handleDiscard = useCallback((e) => {
    if (e) e.preventDefault();
    if (!sending && hasContent() && !address) {
      setPendingDiscard(true);
      return;
    }
    if (autosaveRef.current) {
      window.clearTimeout(autosaveRef.current);
      autosaveRef.current = null;
    }
    if (dirtyRef.current && !sending && hasContent()) {
      performServerSave().catch(() => { /* logged in performServerSave */ });
    }
    hide();
  }, [hide, sending, hasContent, address, performServerSave]);

  const cancelDiscard = useCallback(() => {
    setPendingDiscard(false);
  }, []);

  const confirmDiscard = useCallback(() => {
    setPendingDiscard(false);
    if (autosaveRef.current) {
      window.clearTimeout(autosaveRef.current);
      autosaveRef.current = null;
    }
    hide();
  }, [hide]);

  // Attachments are uploaded directly to S3 via presigned PUT URLs, so
  // the only real ceiling is whatever the receiver SMTP server accepts.
  // Show a soft warning past 20 MB total (Gmail's typical inbound cap is
  // ~25 MB), but don't block the user — they may know the recipient's
  // mail server permits more, or they may be sending to themselves.
  const ATTACHMENT_WARN_BYTES = 20 * 1024 * 1024;

  const onAttachClick = useCallback(() => {
    fileInputRef.current?.click();
  }, []);

  const onFilesSelected = useCallback((e) => {
    const files = Array.from(e.target.files || []);
    e.target.value = ''; // allow re-picking the same file later
    if (files.length === 0) return;
    const additions = files.map((file) => ({
      id: `att-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      filename: file.name,
      mimeType: file.type || 'application/octet-stream',
      file,
      size: file.size,
    }));
    setAttachments(prev => [...prev, ...additions]);
  }, []);

  const attachmentTotalBytes = useMemo(
    () => attachments.reduce((s, a) => s + a.size, 0),
    [attachments]
  );
  const showAttachmentWarning = attachmentTotalBytes > ATTACHMENT_WARN_BYTES;

  const removeAttachment = useCallback((id) => {
    setAttachments(prev => prev.filter(a => a.id !== id));
  }, []);

  const formatBytes = useCallback((n) => {
    if (n < 1024) return `${n} B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
    return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  }, []);

  const onRecipientChange = (e, fieldId) => {
    setRecipient(e.target.value);
    setRecipientField(fieldId);
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

  const removeRecipient = useCallback((list, setList, fieldId, e) => {
    const addr = e.target.value;
    setList(prev => prev.filter(a => a !== addr));
    setRecipient(addr);
    setRecipientField(fieldId);
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
          setList, `recipient-${listName.toLowerCase()}`, e
        )}
        value={addr}
        aria-label={`Remove ${addr}`}
      >
        <X size={12} />
      </button>
    </span>
  );

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
          <label
            className="compose-row__label"
            htmlFor={`from-picker-trigger-${stackIndex}`}
          >From</label>
          <div className="compose-row__field">
            <FromPicker
              items={addressItems}
              domains={effectiveDomains}
              selected={address}
              onSelect={pickAddress}
              onCreated={onAddressCreated}
              stackIndex={stackIndex}
              setMessage={setMessage}
            />
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
              onChange={(e) => onRecipientChange(e, 'recipient-to')}
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
                  onChange={(e) => onRecipientChange(e, 'recipient-cc')}
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
                  onChange={(e) => onRecipientChange(e, 'recipient-bcc')}
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

        {attachments.length > 0 && (
          <>
            <ul className="compose-attachments" aria-label="Attachments">
              {attachments.map((a) => (
                <li
                  key={a.id}
                  className={`compose-attachment-chip${a.pending ? ' compose-attachment-chip--pending' : ''}`}
                >
                  <Paperclip size={12} aria-hidden="true" />
                  <span className="compose-attachment-name" title={a.filename}>{a.filename}</span>
                  <span className="compose-attachment-size">
                    {a.pending ? 'loading…' : formatBytes(a.size)}
                  </span>
                  <button
                    type="button"
                    className="compose-attachment-remove"
                    onClick={() => removeAttachment(a.id)}
                    aria-label={`Remove attachment ${a.filename}`}
                  >
                    <X size={12} />
                  </button>
                </li>
              ))}
            </ul>
            {showAttachmentWarning && (
              <div className="compose-attachment-warning" role="status">
                Attachments total {formatBytes(attachmentTotalBytes)}. Many mail servers
                reject messages over 25 MB; delivery may fail.
              </div>
            )}
          </>
        )}

        <div className="compose-editor">
          <div className="editor-mode-tabs">
            <button type="button"
              className={`editor-mode-tab ${editorMode === 'rich' ? 'is-active' : ''}`}
              onClick={() => setEditorMode('rich')}>Rich Text</button>
            <button type="button"
              className={`editor-mode-tab ${editorMode === 'markdown' ? 'is-active' : ''}`}
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

      <input
        ref={fileInputRef}
        type="file"
        multiple
        className="compose-attachment-input"
        onChange={onFilesSelected}
        aria-hidden="true"
      />

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
            className="compose-attach-btn"
            onClick={onAttachClick}
            aria-label="Attach files"
            title="Attach files"
          >
            <Paperclip size={16} />
          </button>
        </div>
        <div className="compose-bottom__right">
          <span className="compose-saved" aria-live="polite">{savedLabel}</span>
        </div>
      </div>

      <ConfirmDialog
        open={pendingImport !== null}
        title={pendingImport === 'fromRich' ? 'Replace Markdown content?' : 'Replace Rich Text content?'}
        message={pendingImport === 'fromRich'
          ? 'This will replace your current Markdown content with the imported version. Continue?'
          : 'This will replace your current Rich Text content with the imported version. Continue?'}
        confirmLabel="Replace"
        cancelLabel="Cancel"
        onConfirm={confirmImport}
        onCancel={cancelImport}
      />

      <ConfirmDialog
        open={pendingDiscard}
        title="Discard this draft?"
        message="You haven't picked a From address, so this draft can't be saved. Closing will discard what you've typed."
        confirmLabel="Discard"
        cancelLabel="Keep editing"
        destructive
        onConfirm={confirmDiscard}
        onCancel={cancelDiscard}
      />
    </form>
  );
}

export default ComposeOverlay;
