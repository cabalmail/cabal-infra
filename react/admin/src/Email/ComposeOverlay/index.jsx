import React, { useState, useEffect, useCallback, useRef } from 'react';
import './ComposeOverlay.css';
import Request from '../../Addresses/Request';
import { ADDRESS_LIST } from '../../constants';
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

function ComposeOverlay({
  hide, body, recipient: propRecipient, envelope, subject: propSubject,
  type, other_headers, smtp_host, domains
}) {
  const { token, api_url, host } = useAuth();
  const { setMessage } = useAppMessage();
  const api = useApi();

  const [addresses, setAddresses] = useState([]);
  const [address, setAddress] = useState("");
  const [recipient, setRecipient] = useState("");
  const [validationFail, setValidationFail] = useState(false);
  const [To, setTo] = useState([]);
  const [CC, setCC] = useState([]);
  const [BCC, setBCC] = useState([]);
  const [Subject, setSubject] = useState("");
  const [showRequest, setShowRequest] = useState(false);
  const [editorMode, setEditorMode] = useState("rich");
  const [markdownContent, setMarkdownContent] = useState("");
  const markdownRef = useRef(null);

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
        let ccList = envelope.cc.slice();
        const j = ccList.indexOf(propRecipient);
        if (j > -1) ccList.splice(j, 1);
        if (i === -1 && j === -1) {
          setMessage("Warning: You are replying to a blind copy.", true);
        }
        setAddress(propRecipient);
        setTo(toList);
        setCC(ccList);
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
      setAddresses(data.data.Items.map(a => a.address).sort());
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Convert pasted rich text to markdown in the markdown editor
  useEffect(() => {
    const el = markdownRef.current;
    if (!el) return;
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

  const handleSend = useCallback((e) => {
    e.preventDefault();
    const sendButton = e.target;
    const oh = other_headers;
    const irt = oh.message_id || [];
    const msgid = ['<' + randomString(30) + '@' + smtp_host + '>'];
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
    sendButton.classList.add('sending');

    const richEmpty = isEditorEmpty(editor);
    const mdEmpty = !markdownContent.trim();

    let htmlBody, textBody;
    if (richEmpty && mdEmpty) {
      htmlBody = '';
      textBody = '';
    } else if (!richEmpty && mdEmpty) {
      // Only rich has content: auto-generate markdown
      htmlBody = editor.getHTML();
      textBody = turndown.turndown(htmlBody);
    } else if (richEmpty && !mdEmpty) {
      // Only markdown has content: auto-generate HTML
      textBody = markdownContent;
      htmlBody = marked.parse(markdownContent);
    } else {
      // Both have content: send as-is
      htmlBody = editor.getHTML();
      textBody = markdownContent;
    }

    api.sendMessage(
      smtp_host, address, To, CC, BCC, Subject, headers,
      htmlBody, textBody, false
    ).then(() => {
      setMessage("Email sent", false);
      setAddress("");
      setRecipient("");
      setTo([]);
      setCC([]);
      setBCC([]);
      setSubject("");
      setMarkdownContent("");
      editor.commands.clearContent();
      hide();
      sendButton.classList.remove('sending');
    }).catch((err) => {
      setMessage("Error sending email", true);
      sendButton.classList.remove('sending');
      console.log(err);
    });
  }, [other_headers, smtp_host, recipient, To, CC, BCC, Subject, address, addresses,
      editor, markdownContent, api, hide, setMessage, addRecipient, randomString]);

  const handleCancel = (e) => {
    e.preventDefault();
    hide();
  };

  const onSelectChange = (e) => {
    if (e.target.value === "new") {
      setAddress(e.target.value);
      setShowRequest(true);
      return;
    }
    setAddress(e.target.value);
    setShowRequest(false);
  };

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

  const requestCallback = (addr) => {
    setAddresses(prev => [...prev, addr].sort());
    setAddress(addr);
    setShowRequest(false);
  };

  const removeRecipient = useCallback((list, setList, e) => {
    const addr = e.target.value;
    setList(prev => prev.filter(a => a !== addr));
    setRecipient(addr);
  }, []);

  const moveAddress = useCallback((e) => {
    const addr = e.target.getAttribute('data-address');
    const list = e.target.value;
    setTo(prev => prev.filter(a => a !== addr));
    setCC(prev => prev.filter(a => a !== addr));
    setBCC(prev => prev.filter(a => a !== addr));
    switch (list) {
      case "To": setTo(prev => [...prev, addr]); break;
      case "CC": setCC(prev => [...prev, addr]); break;
      case "BCC": setBCC(prev => [...prev, addr]); break;
      default: setTo(prev => [...prev, addr]);
    }
  }, []);

  const obscureEmail = (addr) => {
    return addr.split('').map((c, idx) => {
      switch (c) {
        case '.': return <span key={idx} className="dot"></span>;
        case '@': return <span key={idx} className="amphora"></span>;
        default: return <span key={idx}>{c}</span>;
      }
    });
  };

  const getOptions = () => {
    if (!addresses) return <option key="loading">Loading...</option>;
    return addresses.map((a) => <option value={a} key={a}>{a}</option>);
  };

  const renderRecipientList = (list, listName, removeHandler) => {
    return list.sort().map((a) => (
      <li key={a} className={listName}>
        <div>
          <label>
            <select value={listName} data-address={a} onChange={moveAddress}>
              <option>To</option>
              <option>CC</option>
              <option>BCC</option>
            </select>&#9660;
          </label>
          {obscureEmail(a)}
          <button onClick={(e) => removeHandler(e)} value={a}>&#9746;</button>
        </div>
      </li>
    ));
  };

  return (
    <form className="compose-overlay" onSubmit={handleSubmit}>
      <div className="compose-from-old">
        <label htmlFor="address-from-old" className="address-from-old">From</label>
        <select
          type="text"
          id="address-from-old"
          name="address-from-old"
          className="address-from-old"
          placeholder="Find existing address"
          onChange={onSelectChange}
          value={address}
        >
          <option value="">Select an address</option>
          <option value="new">Create a new address</option>
          {getOptions()}
        </select>
        <Request
          token={token}
          domains={domains}
          api_url={api_url}
          setMessage={setMessage}
          showRequest={showRequest}
          host={host}
          callback={requestCallback}
        />
      </div>
      <label htmlFor="recipient-address">Recipients</label>
      <div
        className="recipients"
        onClick={() => document.getElementById('recipient-address').focus()}
      >
        <ul className="recipient-list" id="recipient-list" tabIndex="0">
          {renderRecipientList(To, "To", (e) => removeRecipient(To, setTo, e))}
          {renderRecipientList(CC, "CC", (e) => removeRecipient(CC, setCC, e))}
          {renderRecipientList(BCC, "BCC", (e) => removeRecipient(BCC, setBCC, e))}
          <li className="recipient-entry">
            <input
              type="email"
              id="recipient-address"
              name="address-to"
              onChange={onRecipientChange}
              onKeyDown={handleKeyDown}
              value={recipient}
              className={`recipient-address${validationFail ? " invalid" : ""}`}
            />
          </li>
        </ul>
      </div>
      <label htmlFor="subject">Subject</label>
      <input
        type="text"
        id="subject"
        name="subject"
        onChange={(e) => setSubject(e.target.value)}
        value={Subject}
      />
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
          placeholder="Compose in Markdown..."
        />
      </div>
      <button onClick={handleSend} className="default" id="compose-send">Send</button>
      <button onClick={handleCancel} id="compose-cancel">Cancel</button>
    </form>
  );
}

export default ComposeOverlay;
