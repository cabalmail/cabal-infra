- Android: **Resume prompt names the feed.** The cross-device resume offer
  for a feed cursor named the article rather than the feed it came from
  whenever this install's feed catalogue had not been synced: a launch that
  has never opened Feeds has no local catalogue at all, so the lookup behind
  the name could never hit. The subscription now takes the same store-first,
  server-second ladder the item already took.
