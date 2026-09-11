- **Per-item feed state sync in `/rss_list_items`.** A `state_since`
  cursor (single subscription) returns the caller's read/favorite rows
  changed since the cursor, from a new `by_updated` index on
  `cabal-rss-user-item-state` (every state write now sets `updated_key`).
  An empty cursor pulls the feed's whole state partition first, which is
  how an existing device's cache repairs itself. Items and state rows also
  carry `is_read_explicit`, so clients can tell a hand-made mark from the
  watermark rule.
