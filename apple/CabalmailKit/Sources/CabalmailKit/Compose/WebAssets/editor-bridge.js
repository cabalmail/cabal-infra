// Cabalmail rich-text editor bridge.
//
// Mirrors the React composer's behavior so the Apple clients produce the
// same wire bytes when the user sends a message. The contract is small:
//
//   window.cabal.getHTML()                -> HTML in the editor
//   window.cabal.setHTML(html, block, md) -> replace editor content,
//                                            sanitized; `block` turns
//                                            network images into text,
//                                            except those in Markdown `md`
//   window.cabal.isEmpty()                -> true when nothing is visible
//   window.cabal.markdownToHtml(md)       -> uses marked + flattenParagraphs
//   window.cabal.htmlToMarkdown(html)     -> uses turndown w/ React's custom
//                                            paragraph + lineBreak rules,
//                                            zero-width-space placeholder
//                                            stripped before return
//   window.cabal.styleParagraphs(html)    -> regex injection of margin:0
//   window.cabal.exec(name, value)        -> document.execCommand wrapper
//   window.cabal.insertPlainText(text)    -> escaped text at the caret,
//                                            \n -> <br> (paste w/o format)
//   window.cabal.activeStates()           -> snapshot of bold/italic/etc.
//                                            for the SwiftUI toolbar
//
// Native code talks back via window.webkit.messageHandlers.cabal when it
// exists; outside a WKWebView (e.g. /unit tests served in a browser) the
// post is a no-op.

(function () {
  'use strict';

  const editor = document.getElementById('editor');

  function postNative(payload) {
    const handlers = (window.webkit && window.webkit.messageHandlers) || null;
    if (handlers && handlers.cabal) {
      handlers.cabal.postMessage(payload);
    }
  }

  // --- conversion helpers ---------------------------------------------------

  // Mirror React's ComposeOverlay flattenParagraphs: blank-line paragraph
  // breaks collapse to explicit <br><br>s so the editor's "Enter = hard
  // break" idiom round-trips.
  function flattenParagraphs(html) {
    return html.replace(/<\/p>\s*<p[^>]*>/g, '<br><br>');
  }

  // Mirror React's styleParagraphs: inline margin:0 on every <p> that
  // doesn't already carry a style attribute, so recipients don't fall back
  // to their mail client's default ~1em paragraph margin.
  function styleParagraphs(html) {
    return html.replace(/<p(\s[^>]*)?>/g, function (match, attrs) {
      if (attrs && /\sstyle\s*=/i.test(attrs)) return match;
      return '<p' + (attrs || '') + ' style="margin:0">';
    });
  }

  function markdownToHtml(md) {
    return flattenParagraphs(window.marked.parse(md || '', { breaks: true, async: false }));
  }

  // Turndown with React's exact options + paragraph/line-break rules. The
  // U+200B placeholder defeats turndown's adjacent-newline collapsing so a
  // run of <br>s accumulates one newline each.
  const ZWSP = '​';
  const turndown = new window.TurndownService({ headingStyle: 'atx', hr: '---' });
  turndown.addRule('paragraph', {
    filter: 'p',
    replacement: function (content) { return content + ZWSP + '\n'; }
  });
  turndown.addRule('lineBreak', {
    filter: 'br',
    replacement: function () { return ZWSP + '\n'; }
  });

  function htmlToMarkdown(html) {
    return turndown.turndown(html || '').replace(/​/g, '');
  }

  // --- editor surface -------------------------------------------------------

  // Elements that are content without contributing text. An emptiness test
  // that only read text would throw an image-only or rule-only body away.
  const NON_TEXT_CONTENT = 'img, hr, table, iframe, video, audio, object, embed';

  function isEmpty() {
    const html = editor.innerHTML;
    if (!html) return true;
    if (editor.querySelector(NON_TEXT_CONTENT)) return false;
    // Select-all + delete does not leave the element empty: WebKit keeps the
    // block scaffolding behind, `<p><br></p>` on a document that had
    // paragraphs and `<br>` on one that never did. Ask what the user can see
    // rather than enumerating the shapes WebKit leaves behind (#1138).
    return editor.textContent.trim() === '';
  }

  function getHTML() {
    // Empty contenteditable renders an internal <br> on some WebKit
    // versions; normalize that out so the wire payload matches what the
    // user sees (truly empty).
    if (isEmpty()) return '';
    return editor.innerHTML;
  }

  // --- inbound HTML ---------------------------------------------------------

  // Markup that reaches the editor from outside it: the reply, forward and
  // mailto seeds (marked output over text somebody else wrote), a reopened
  // draft, an HTML paste. This page runs script for the editor itself, so
  // that markup must not bring any of its own. It is parsed into an inert
  // <template> (nothing in there runs or loads), cut down to formatting,
  // and only then attached to the live document.

  // Formatting elements, kept with their allowed attributes. Any other
  // HTML element is unwrapped (its children stay, the tag goes), except
  // the ones below, which go with everything inside them.
  const KEEP_ELEMENTS = new Set([
    'A', 'ABBR', 'ADDRESS', 'ARTICLE', 'ASIDE', 'B', 'BDI', 'BDO', 'BIG',
    'BLOCKQUOTE', 'BR', 'CAPTION', 'CENTER', 'CITE', 'CODE', 'COL', 'COLGROUP',
    'DD', 'DEL', 'DFN', 'DIV', 'DL', 'DT', 'EM', 'FIGCAPTION', 'FIGURE', 'FONT',
    'FOOTER', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'HEADER', 'HR', 'I', 'IMG',
    'INPUT', 'INS', 'KBD', 'LI', 'MAIN', 'MARK', 'NAV', 'OL', 'P', 'PRE', 'Q',
    'RP', 'RT', 'RUBY', 'S', 'SAMP', 'SECTION', 'SMALL', 'SPAN', 'STRIKE',
    'STRONG', 'SUB', 'SUP', 'TABLE', 'TBODY', 'TD', 'TFOOT', 'TH', 'THEAD',
    'TIME', 'TR', 'TT', 'U', 'UL', 'VAR', 'WBR'
  ]);

  const DROP_ELEMENTS = new Set([
    'APPLET', 'AREA', 'AUDIO', 'BASE', 'BUTTON', 'CANVAS', 'DIALOG', 'EMBED',
    'FRAME', 'FRAMESET', 'IFRAME', 'LINK', 'MAP', 'META', 'NOEMBED',
    'NOFRAMES', 'NOSCRIPT', 'OBJECT', 'OPTGROUP', 'OPTION', 'PARAM',
    'PLAINTEXT', 'PORTAL', 'SCRIPT', 'SELECT', 'SOURCE', 'STYLE', 'TEMPLATE',
    'TEXTAREA', 'TITLE', 'TRACK', 'VIDEO', 'XMP'
  ]);

  // Every other attribute goes, every on* handler and id / name (which can
  // shadow the document's own methods) among them.
  const KEEP_ATTRIBUTES = new Set([
    'align', 'alt', 'bgcolor', 'border', 'cellpadding', 'cellspacing',
    'checked', 'class', 'color', 'colspan', 'datetime', 'dir', 'disabled',
    'face', 'height', 'href', 'lang', 'nowrap', 'reversed', 'rowspan', 'size',
    'span', 'src', 'start', 'style', 'title', 'type', 'valign', 'value', 'width'
  ]);

  const HTML_NAMESPACE = 'http://www.w3.org/1999/xhtml';

  function urlScheme(value) {
    try {
      return new URL(value, document.baseURI).protocol;
    } catch (_) {
      return null;
    }
  }

  function isRemote(scheme) {
    return scheme === 'http:' || scheme === 'https:';
  }

  // href: anything but script and inline documents. Clicks never navigate
  // the composer (the native policy cancels them), but a javascript: link
  // would still run if anything followed it.
  function allowsHref(value) {
    const scheme = urlScheme(value);
    return scheme !== null && scheme !== 'javascript:' && scheme !== 'vbscript:' && scheme !== 'data:';
  }

  // img src: cid: parts, data: images, ordinary addresses.
  function allowsImageSource(value) {
    const scheme = urlScheme(value);
    if (scheme === null || scheme === 'javascript:' || scheme === 'vbscript:') return false;
    if (scheme === 'data:') return /^\s*data:image\//i.test(value);
    return true;
  }

  // `policy.blockRemote` is set when the markup quotes somebody else's
  // message. Inline style goes too then: CSS can fetch (url(), image-set())
  // and a CSS escape hides that from any check of the attribute's text,
  // while a quoted plain-text part has no styling of its own to lose.
  function cleanAttributes(element, policy) {
    const tag = element.tagName;
    for (const attr of Array.from(element.attributes)) {
      const name = attr.name.toLowerCase();
      const value = attr.value;
      let keep = KEEP_ATTRIBUTES.has(name) && attr.namespaceURI === null;
      if (keep && name === 'href') keep = tag === 'A' && allowsHref(value);
      if (keep && name === 'src') keep = tag === 'IMG' && allowsImageSource(value);
      if (keep && (name === 'checked' || name === 'disabled')) keep = tag === 'INPUT';
      if (keep && name === 'style' && policy.blockRemote) keep = false;
      if (!keep) element.removeAttribute(attr.name);
    }
  }

  // An image that would load from the network turns into text: its alt
  // text if it has some, else its address. Images the user put in their
  // own signature (`policy.keepSources`) stay.
  function replaceRemoteImage(img, policy) {
    const src = img.getAttribute('src');
    if (!src || !isRemote(urlScheme(src)) || policy.keepSources.has(src)) return false;
    const label = (img.getAttribute('alt') || '').trim() || src;
    img.replaceWith(img.ownerDocument.createTextNode(label));
    return true;
  }

  function cleanNode(node, policy) {
    for (const child of Array.from(node.childNodes)) {
      if (child.nodeType === Node.TEXT_NODE) continue;
      if (child.nodeType !== Node.ELEMENT_NODE) {
        child.remove();
        continue;
      }
      const tag = child.tagName;
      if (child.namespaceURI !== HTML_NAMESPACE || DROP_ELEMENTS.has(tag) ||
          (tag === 'INPUT' && (child.getAttribute('type') || '').toLowerCase() !== 'checkbox')) {
        child.remove();
        continue;
      }
      cleanNode(child, policy);
      if (!KEEP_ELEMENTS.has(tag)) {
        child.replaceWith(...Array.from(child.childNodes));
        continue;
      }
      cleanAttributes(child, policy);
      if (tag === 'INPUT') child.setAttribute('disabled', '');
      if (tag === 'IMG' && policy.blockRemote) replaceRemoteImage(child, policy);
    }
  }

  const BLOCK_NOTHING = { blockRemote: false, keepSources: new Set() };

  // Returns a DocumentFragment owned by this document, safe to attach.
  function sanitize(html, policy) {
    const template = document.createElement('template');
    template.innerHTML = html || '';
    cleanNode(template.content, policy);
    return document.importNode(template.content, true);
  }

  // Markup from outside the editor, for the paths that hand it to
  // execCommand. Paragraphs are flattened first: nothing may edit the
  // string after the sanitizer has passed it.
  function sanitizeForInsert(html) {
    const holder = document.createElement('div');
    holder.appendChild(sanitize(flattenParagraphs(html), BLOCK_NOTHING));
    return holder.innerHTML;
  }

  // The image addresses in Markdown the user wrote themselves.
  function imageSources(markdown) {
    const sources = new Set();
    if (!markdown) return sources;
    const template = document.createElement('template');
    template.innerHTML = markdownToHtml(markdown);
    for (const img of template.content.querySelectorAll('img[src]')) {
      sources.add(img.getAttribute('src'));
    }
    return sources;
  }

  // `blockRemoteImages` is set in a reply or forward, so quoting a message
  // never fetches anything from its sender's servers; `trustedMarkdown` is
  // the user's signature, whose images stay. A reopened draft and a paste
  // keep their images.
  function setHTML(html, blockRemoteImages, trustedMarkdown) {
    const policy = blockRemoteImages
      ? { blockRemote: true, keepSources: imageSources(trustedMarkdown) }
      : BLOCK_NOTHING;
    editor.replaceChildren(sanitize(html, policy));
  }

  // Tag names that should keep contenteditable's default Enter behavior
  // (new list item / literal newline inside a code block / exit-to-paragraph
  // out of a heading). Everywhere else Enter inserts <br>, matching React.
  const ENTER_DEFAULT_TAGS = new Set(['LI', 'PRE', 'CODE', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6']);

  function shouldUseDefaultEnter() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return false;
    let node = sel.getRangeAt(0).startContainer;
    while (node && node !== editor) {
      if (node.nodeType === 1 && ENTER_DEFAULT_TAGS.has(node.tagName)) return true;
      node = node.parentNode;
    }
    return false;
  }

  editor.addEventListener('keydown', function (event) {
    if (event.key === 'Enter' && !event.shiftKey && !event.metaKey && !event.ctrlKey) {
      if (shouldUseDefaultEnter()) return;
      event.preventDefault();
      document.execCommand('insertLineBreak');
      return;
    }
    // Cmd-Shift-V pastes without formatting. Alt is allowed so the stock
    // macOS Edit-menu equivalent (Paste and Match Style, Cmd-Opt-Shift-V)
    // lands here too instead of reaching the paste listener below, which
    // would prefer the HTML flavor and paste *with* formatting. Match on
    // event.code as well because Opt-Shift-V changes event.key to a
    // composed character on macOS keyboards.
    if (event.metaKey && event.shiftKey && !event.ctrlKey &&
        (event.code === 'KeyV' || event.key.toLowerCase() === 'v')) {
      event.preventDefault();
      // clipboardData is only readable inside a genuine paste event, so
      // ask native to read the pasteboard and call insertPlainText back.
      postNative({ type: 'pastePlain' });
    }
  });

  function escapeHtml(text) {
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  }

  // Shared by the plain-flavor paste path and paste-without-formatting:
  // insert escaped text at the caret, each newline becoming a <br>.
  function insertPlainText(text) {
    if (typeof text !== 'string') return;
    const withBr = escapeHtml(text).replace(/\r\n?|\n/g, '<br>');
    document.execCommand('insertHTML', false, withBr);
  }

  // Match React's transformPastedHTML + clipboardTextParser: HTML paste
  // flattens paragraph boundaries to <br><br>; plain-text paste turns each
  // \n into a <br>. Both keep the surrounding paragraph intact instead of
  // dropping a fresh <p> at the cursor.
  editor.addEventListener('paste', function (event) {
    const html = event.clipboardData && event.clipboardData.getData('text/html');
    const text = event.clipboardData && event.clipboardData.getData('text/plain');
    if (html) {
      event.preventDefault();
      document.execCommand('insertHTML', false, sanitizeForInsert(html));
      return;
    }
    if (typeof text === 'string') {
      event.preventDefault();
      insertPlainText(text);
    }
  });

  // Markup dropped from outside the editor takes the paste path, at the
  // drop point. A drag within the editor moves content that is already
  // clean, so WebKit handles that one.
  let draggingFromEditor = false;
  editor.addEventListener('dragstart', function () { draggingFromEditor = true; });
  editor.addEventListener('dragend', function () { draggingFromEditor = false; });
  editor.addEventListener('drop', function (event) {
    const html = event.dataTransfer && event.dataTransfer.getData('text/html');
    if (draggingFromEditor || !html) return;
    event.preventDefault();
    const point = document.caretRangeFromPoint
      ? document.caretRangeFromPoint(event.clientX, event.clientY)
      : null;
    if (point && editor.contains(point.startContainer)) {
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(point);
    }
    document.execCommand('insertHTML', false, sanitizeForInsert(html));
  });

  editor.addEventListener('input', function () {
    postNative({ type: 'input', empty: isEmpty() });
  });

  editor.addEventListener('focus', function () {
    postNative({ type: 'focus' });
  });
  editor.addEventListener('blur', function () {
    postNative({ type: 'blur' });
  });

  // Selection changes are document-scoped — filter to selections that fall
  // inside our editor so we don't spam the bridge while the user clicks
  // around other parts of the WKWebView host.
  document.addEventListener('selectionchange', function () {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return;
    const node = sel.getRangeAt(0).startContainer;
    let walker = node;
    while (walker) {
      if (walker === editor) {
        postNative({ type: 'selection', states: activeStates() });
        return;
      }
      walker = walker.parentNode;
    }
  });

  // --- toolbar state --------------------------------------------------------

  function isInList(tag) {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return false;
    let node = sel.getRangeAt(0).startContainer;
    while (node && node !== editor) {
      if (node.nodeType === 1 && node.tagName === tag) return true;
      node = node.parentNode;
    }
    return false;
  }

  function currentHeadingLevel() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return 0;
    let node = sel.getRangeAt(0).startContainer;
    while (node && node !== editor) {
      if (node.nodeType === 1) {
        const m = /^H([1-6])$/.exec(node.tagName);
        if (m) return parseInt(m[1], 10);
      }
      node = node.parentNode;
    }
    return 0;
  }

  function currentAlignment() {
    try {
      if (document.queryCommandState('justifyCenter')) return 'center';
      if (document.queryCommandState('justifyRight')) return 'right';
    } catch (_) { /* unsupported */ }
    return 'left';
  }

  function isInLink() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return false;
    let node = sel.getRangeAt(0).startContainer;
    while (node && node !== editor) {
      if (node.nodeType === 1 && node.tagName === 'A') return true;
      node = node.parentNode;
    }
    return false;
  }

  function activeStates() {
    function state(name) {
      try { return document.queryCommandState(name); } catch (_) { return false; }
    }
    return {
      bold: state('bold'),
      italic: state('italic'),
      underline: state('underline'),
      strikethrough: state('strikeThrough'),
      bulletList: isInList('UL'),
      orderedList: isInList('OL'),
      headingLevel: currentHeadingLevel(),
      alignment: currentAlignment(),
      link: isInLink(),
      canUndo: (function () { try { return document.queryCommandEnabled('undo'); } catch (_) { return false; } })(),
      canRedo: (function () { try { return document.queryCommandEnabled('redo'); } catch (_) { return false; } })()
    };
  }

  // --- commands -------------------------------------------------------------

  function applyAlignment(direction) {
    document.execCommand('justify' + direction);
  }

  function applyHeading(level) {
    if (level === 0 || level === currentHeadingLevel()) {
      document.execCommand('formatBlock', false, 'P');
    } else {
      document.execCommand('formatBlock', false, 'H' + level);
    }
  }

  function exec(name, value) {
    switch (name) {
      case 'bold':
      case 'italic':
      case 'underline':
        document.execCommand(name);
        break;
      case 'strikethrough':
        document.execCommand('strikeThrough');
        break;
      case 'bulletList':
        document.execCommand('insertUnorderedList');
        break;
      case 'orderedList':
        document.execCommand('insertOrderedList');
        break;
      case 'alignLeft':
        applyAlignment('Left');
        break;
      case 'alignCenter':
        applyAlignment('Center');
        break;
      case 'alignRight':
        applyAlignment('Right');
        break;
      case 'heading':
        applyHeading(value || 0);
        break;
      case 'horizontalRule':
        document.execCommand('insertHorizontalRule');
        break;
      case 'createLink':
        if (value) document.execCommand('createLink', false, value);
        break;
      case 'unlink':
        document.execCommand('unlink');
        break;
      case 'undo':
        document.execCommand('undo');
        break;
      case 'redo':
        document.execCommand('redo');
        break;
      default:
        break;
    }
    postNative({ type: 'selection', states: activeStates() });
  }

  function focus() {
    editor.focus();
  }

  // Places the caret at the very beginning of the editor before focusing,
  // so reply/reply-all opens with the cursor above the seeded separator +
  // attribution + quoted original block.
  function focusAtStart() {
    editor.focus();
    const selection = window.getSelection();
    if (!selection) return;
    const range = document.createRange();
    range.setStart(editor, 0);
    range.collapse(true);
    selection.removeAllRanges();
    selection.addRange(range);
  }

  function setPlaceholder(text) {
    if (text) editor.setAttribute('data-placeholder', text);
    else editor.removeAttribute('data-placeholder');
  }

  // --- public surface -------------------------------------------------------

  window.cabal = {
    getHTML: getHTML,
    setHTML: setHTML,
    isEmpty: isEmpty,
    markdownToHtml: markdownToHtml,
    htmlToMarkdown: htmlToMarkdown,
    styleParagraphs: styleParagraphs,
    activeStates: activeStates,
    exec: exec,
    insertPlainText: insertPlainText,
    focus: focus,
    focusAtStart: focusAtStart,
    setPlaceholder: setPlaceholder
  };

  postNative({ type: 'ready' });
})();
