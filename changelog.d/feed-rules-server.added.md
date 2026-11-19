- **Feed rules on the server.** `/get_rules` and `/set_rules` carry a
  second list, `feedRules`, beside `rules` in the same row and under the
  same version. It is optional in a save: a request without it, which is
  what every client that predates feed rules sends, leaves the stored
  list untouched. A feed rule has conditions (`feed`, `title`, `author`,
  `summary`) and the three marks a mail rule can make (`flag`, `flags`,
  `markRead`). When the `rss_fetch` worker inserts an item it evaluates
  each subscriber's feed rules against it and writes the outcome to
  their state row, after the fetch is recorded and best effort, so a
  rules failure never fails ingestion; a rule that sets a custom flag no
  longer in the palette is skipped whole, as a mail rule is. A save that
  changes only the feed rules does not notify the imap tier. No client
  has an editor for feed rules yet
  (docs/1.x/cross-media-ux-plan.md, Phase 4; docs/mail-rules.md, "Feed
  rules").
