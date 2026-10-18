- Apple: **Unread count after two conflicting read-state changes.** When a
  mark-read failed after the same message had been marked unread elsewhere,
  the failure's take-back moved the folder's unread count a second time, so
  the sidebar and the Inbox badge read one unread too many (one too few in
  the mirror case, which hides a real unread message) until the next STATUS
  refresh. A write the server has taken now holds the count, and the older
  write's failure leaves it alone.
