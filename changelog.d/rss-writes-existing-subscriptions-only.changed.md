- **Subscription changes apply only to existing subscriptions.** When
  its write finds the subscription gone, `/rss_update_subscription`
  answers 404 `unknown_subscription`, and `/rss_mark_all_read` and
  `/rss_delete_folder` skip it and leave it out of their counts.
  Mark-all-read likewise flips only the unread marks that still exist
  when it writes.
