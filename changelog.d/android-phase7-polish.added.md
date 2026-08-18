- **Android platform polish (Phase 7).** The client grows into each form
  factor: Mail / Addresses / Folders / Settings become top-level
  destinations in a bottom navigation bar on phones and a navigation rail
  from medium widths up; on tablets and foldables the message list and the
  open message sit side by side (hinge-aware), the open row is highlighted,
  and the resume cursor lands in that split with the message preselected.
  Hardware keyboards get Ctrl+N (compose), Ctrl+R / Ctrl+Shift+R (reply /
  reply-all), Ctrl+Shift+U / Ctrl+Shift+L (toggle read / flag) and a j/k
  row cursor with Enter to open. Visible lists poll quietly every minute;
  an "Offline — showing cached mail" banner appears while there is no
  validated internet path, cached messages stay readable, and a send that
  fails offline is queued with a stable Message-ID and sent automatically
  on reconnect (the server deduplicates a retry it already delivered).
  Optional new-mail notifications check INBOX in the background about
  every 15 minutes (opt in from Settings; the permission is requested on
  Android 13+); tapping one opens the message. Reader-side flag and dispose
  changes now mirror into the list without a refresh, every failure gets a
  plain-language message, an expired session returns to sign-in with a
  reason, predictive back is enabled, and release builds are shrunk and
  obfuscated with R8 (37.8 MB debug → 4.9 MB release).
