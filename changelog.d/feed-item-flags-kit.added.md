- **CabalmailKit: custom flags on feed items.** A feed item now carries
  the custom flags the server holds for it (`RssItem.flags`, palette
  slots as on mail), and `RssSyncEngine.setFlag` sets or clears one. The
  feed store moves to schema 7 for them. A change made offline waits in
  the queue per item and slot, the latest for each, and is sent as an add
  or a remove of that one slot, so two devices that change different
  flags of one item both take effect, and what the server reports never
  overwrites a slot whose change is still queued. An add the server
  refuses, because the flag was disabled or deleted on another device, is
  dropped and taken off the item instead of holding every later change
  behind it. A build from 1.50.0 on that meets a schema 7 file sets it
  aside, and its unsent flag changes come back when a newer build
  returns. `SearchQuery` gains `keyword`, one custom flag to narrow a
  mail search to. No screen uses either yet. Kit half of cross-media
  Phase 2 (`docs/1.x/cross-media-ux-plan.md`).
