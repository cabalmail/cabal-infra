- Apple: **Per-feed reader settings that stick.** The feed reader's toolbar
  toggles are now remembered per feed: choosing the article view, reader or
  original styling, or showing or hiding remote content on one item makes
  the next item in that feed open the same way, and the feed's settings sheet
  shows the same choice. The sheet's existing Open and Styling settings had
  no effect because the reader built its state before the feed's settings
  had loaded; they now apply. A new per-feed "Remote content" setting (App
  setting / Show / Hide) backs the remote-content toggle, with a matching
  `default_remote_content` field on the subscription API.
