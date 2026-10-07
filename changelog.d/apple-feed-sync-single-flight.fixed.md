- Apple: **Feeds refresh once, and one broken feed no longer stalls a
  list.** Opening the app, the Feeds sidebar and a feed list used to start
  two or three overlapping refreshes of every feed, fetching the feed list
  twice over; they now share one. Refreshing a folder or All Feeds used to
  stop at the first feed that failed, leaving the feeds after it and any
  read or flag changes made offline unsent until the next refresh; every
  feed is now tried, four at a time, and the queued changes still go. The
  sidebar's "couldn't reach the server" line no longer appears when only
  some feeds, or the queued changes, failed (#1904).
