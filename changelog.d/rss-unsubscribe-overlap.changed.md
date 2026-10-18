- **One unsubscribe per feed subscription.** Of two overlapping
  `/rss_unsubscribe` requests for the same subscription, one removes it and
  the other answers 404 `unknown_subscription`, as a repeat after the first
  has finished does.
