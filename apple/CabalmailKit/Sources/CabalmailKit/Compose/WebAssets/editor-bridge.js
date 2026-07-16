// Cabalmail rich-text editor bridge.
//
// Mirrors the React composer's behavior so the Apple clients produce the
// same wire bytes when the user sends a message. The contract is small:
//
//   window.cabal.getHTML()                -> HTML in the editor
//   window.cabal.setHTML(html)            -> replace editor content
//   window.cabal.isEmpty()                -> true for <p></p> / ''
//   window.cabal.markdownToHtml(md)       -> uses marked + flattenParagraphs
//   window.cabal.htmlToMarkdown(html)     -> uses turndown w/ React's custom
//                                            paragraph + lineBreak rules,
//                                            zero-width-space placeholder
//                                            stripped before return
//   window.cabal.styleParagraphs(html)    -> regex injection of margin:0
//   window.cabal.exec(name, value)        -> document.execCommand wrapper
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

  function isEmpty() {
    const html = editor.innerHTML;
    return !html || html === '<p></p>' || html === '<br>';
  }

  function getHTML() {
    // Empty contenteditable renders an internal <br> on some WebKit
    // versions; normalize that out so the wire payload matches what the
    // user sees (truly empty).
    if (isEmpty()) return '';
    return editor.innerHTML;
  }

  function setHTML(html) {
    editor.innerHTML = html || '';
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
    }
  });

  function escapeHtml(text) {
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
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
      document.execCommand('insertHTML', false, flattenParagraphs(html));
      return;
    }
    if (typeof text === 'string') {
      event.preventDefault();
      const withBr = escapeHtml(text).replace(/\r\n?|\n/g, '<br>');
      document.execCommand('insertHTML', false, withBr);
    }
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
    focus: focus,
    focusAtStart: focusAtStart,
    setPlaceholder: setPlaceholder
  };

  postNative({ type: 'ready' });
})();
