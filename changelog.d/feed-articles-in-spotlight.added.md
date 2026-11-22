- Apple: **Feed articles in Spotlight.** A system search now finds feed
  articles as it finds mail: by words from an article's title, its text or
  its author. Choosing a result opens the app on that article, in its own
  feed's list, in the window the result came to (else the one last used).
  An article is given to Spotlight when it syncs, and each feed's newest
  200 are given again when a session starts, which is also what indexes
  the articles already on the device after the update. Everything stays
  on the device, as mail's entries do. Unsubscribing from a feed takes its
  articles out of Spotlight, and signing out takes out everything, mail
  and feeds; the session being signed out now stops indexing before that
  wipe, so a sync still in flight cannot put an entry back. A result for
  a feed the account has since left opens nothing and is removed. Under
  it: `SpotlightFeedIndexer` beside the mail indexer, fed by
  `RssSyncEngine` through a queue so a feed sync never waits on
  Spotlight; a `DeepLink.feedItem` link; and `CabalmailClient.make` takes
  the search index to use, so tests record what is indexed instead of
  writing to the device's index.
