- Android: **Feed error line counts only feeds.** One sync pass reported
  catalog, per-feed and offline-queue failures in a single map keyed by
  subscription id, and the feed list showed its "Could not refresh feeds"
  line when that map was as big as the subscription list. A failed queue
  push therefore counted as a failed feed: the line appeared while a feed
  had synced fine, or stayed away when every feed had failed. The pass
  returns an `RssSyncReport` with the three kinds apart, as the Apple kit
  does.
