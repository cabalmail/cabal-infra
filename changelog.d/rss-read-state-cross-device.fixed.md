- Apple: **Feed read state now agrees across devices.** An item marked
  read, unread, or favorite on one device reaches the others: the feed
  sync pulls the server's per-item state changes alongside new items,
  where before only new items and mark-all-read travelled, so a mark made
  elsewhere never arrived. A mark-unread on an item older than the
  feed's mark-all-read point also stays unread when the item is listed
  again, instead of the local watermark flipping it back to read. Offline
  changes now replay in the order they were made, so "mark all read, then
  mark one item unread" no longer ends with the server marking that item
  read again.
