- **Reads of the settings row that could miss a write made a moment
  earlier.** `get_preferences`, and the flag-list checks in `set_flag`
  and `rss_set_item_state`, read the row with an eventually consistent
  read, while the Apple apps read straight after they write: a settings
  pull right after a push, and a flag put on a feed item right after the
  push that created it. A read of the older row could put the older
  settings back, or refuse the flag a second time. All three now read
  consistently (#2442).
