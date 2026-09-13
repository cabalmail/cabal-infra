- Android: **Feeds.** A feed reader beside mail (phase 6b of the RSS
  plan), built against the Apple reader as it shipped: a Feeds tab with the
  folder tree, unread badges rolled up per folder, feed health marks, and
  an All Feeds view; item lists with sticky All / Unread / Favorites pills
  (feeds start on Unread), the four orderings, swipe to mark read or
  favorite, per-feed search over what is cached, "Load older items" only
  while the server has more, and a confirmed mark-all-read; a reader that
  opens each item the way its feed's settings say (feed content or the
  article, reader or original styling, remote content per feed) and
  remembers the toggles per feed; the publisher's article in a web view
  whose cookies belong to that one feed. Everything reads from a local
  store, so lists and items work offline and changes made offline are
  pushed when a connection returns. Pictures still addressed over plain
  `http` now load over `https` in mail and feeds alike. Subscribing,
  folders, and OPML arrive in the next phase.
