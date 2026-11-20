- Apple: **Rules for feed items.** Settings > Rules has a second list,
  "Feed items", under the mail rules, which now sit under "Email
  messages". A feed rule flags a new item or marks it read as soon as its
  feed is fetched, before any device opens the feed: pick the feed it
  applies to (or all feeds), add conditions on the item's title, author
  or summary, and switch on any of your flags and Mark as read. Every
  enabled rule that matches applies, so their order is only how the list
  is shown. A rule runs once, when an item first arrives; it does not
  reach back to items already there. A "Flag matching items" template
  joins the starter templates. Feed rules sync with the mail rules and
  save with them: one device's edit to either list is a conflict for a
  device still holding the older set, and an edit to the mail rules
  alone leaves the stored feed rules untouched (`feedRules` on
  `/get_rules` and `/set_rules`; docs/mail-rules.md, "Feed rules").
