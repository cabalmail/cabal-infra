- **RSS reader API (phase 3 of the RSS plan).** Eleven Cognito-authorized
  endpoints under the existing gateway: subscribe (with canonical-URL
  dedup against shared feeds, feed autodiscovery from a web page, and an
  immediate first fetch), unsubscribe (purging a feed when its last
  subscriber leaves), per-subscription settings, folder create/update/
  delete with reparenting, item listing with computed unread state and a
  per-subscription read watermark, favorites via the sparse index, an
  incremental `since` cursor keyed on ingest time for client caches, item
  fetch with spilled bodies inlined, batched read/favorite state, and
  mark-all-read. Reference in `docs/rss.md`. No client uses it yet; the
  Apple client follows in phase 5.
