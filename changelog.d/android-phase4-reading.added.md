- Android: **Folder list, message list, and reader.** Folder list with
  unread badges and pull-to-refresh; index-addressed sliding-window message
  list (placeholder rows, band loading through the envelope cache) with
  read/flagged emphasis, attachment, priority, and auth-failure indicators;
  and a message reader - hardened WebView (no JavaScript, remote content
  blocked until a per-message opt-in), plain-text fallback, flag/read
  toggles, archive-or-purge dispose, and body caching (Phase 4 core).
