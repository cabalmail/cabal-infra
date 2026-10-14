// Relay page-level script errors to native. Loaded before the library
// <script> tags so a failure while loading or evaluating marked / turndown /
// editor-bridge.js (which would prevent the bridge's "ready" post and park
// every native await) is surfaced instead of silently hanging the compose
// surface (#734). A file rather than an inline <script> because the page's
// content security policy refuses inline script.
// Capture phase: resource-load failures (a missing <script src>) fire on
// the element and don't bubble, so a bubble-phase listener would only see
// runtime throws.
window.addEventListener('error', function (event) {
  var handlers = window.webkit && window.webkit.messageHandlers;
  if (!handlers || !handlers.cabal) return;
  var target = event.target;
  var message = event.message
    ? String(event.message)
    : 'failed to load ' + String((target && target.src) || 'resource').split('/').pop();
  handlers.cabal.postMessage({
    type: 'error',
    message: message,
    source: String(event.filename || '').split('/').pop()
  });
}, true);
