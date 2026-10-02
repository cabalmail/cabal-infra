- **Tap-time watermark for `/rss_mark_all_read`.** The endpoint takes an
  optional `watermark` (ISO 8601), clamped to the server's now and never
  moved backwards, and flips explicit unreads only up to it. A client
  replaying a mark-all-read queued offline sends the moment of the tap, so
  items that arrived in between are no longer marked read. Requests
  without the field behave as before.
