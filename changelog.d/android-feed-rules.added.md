- Android: **Rules for feed items.** Settings > Rules (it was "Mail
  rules") has a second list, "Feed items", under the mail rules: a feed
  rule flags a new feed item or marks it read when its feed is fetched,
  before you open the feed. A rule has the feed it applies to (All feeds,
  or one subscription), conditions on the item's title, author and
  summary, and any of your flags and Mark as read. The Add button asks
  which kind of rule to add, and the first-run screen has a "Flag
  matching items" template. The two lists are saved together under one
  version, so a save from another device is a conflict for either; an
  edit to the mail rules alone leaves the feed rules untouched. A feed
  rule that uses something this version does not know is listed
  read-only and kept as it is. The kit gains `FeedRule`,
  `FeedRulesValidator` and an optional feed list on the rules save call.
