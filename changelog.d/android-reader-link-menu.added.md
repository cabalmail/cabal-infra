- Android: **Link menu in the reader.** Tapping a link in a message body now
  opens an action sheet — matching the Apple clients' link popover — showing
  the full destination URL with copy, open (in the browser, or the handling
  app for `mailto:` and other schemes), and share actions. Previously the
  reader's hardened WebView swallowed link taps outright, leaving links
  inert. Plain-text bodies get the same treatment: web URLs, `www.` hosts,
  and email addresses are detected and feed the same menu. Executable and
  local schemes (`javascript:`, `data:`, `file:`, `intent:`, …) stay
  silently swallowed, and the HTML body no longer reloads — losing the
  reading position — when unrelated screen state changes.
