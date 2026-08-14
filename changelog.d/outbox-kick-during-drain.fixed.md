- Apple: **A message queued while the outbox was draining no longer waits for
  the next network change.** Sending while an earlier queued message was being
  retried enqueued the new message behind a drain that had already listed the
  outbox, and the kick meant to catch it was dropped because a drain was
  running — so the message sat unsent until reachability next changed, which on
  a stable connection could be a long time. A kick that arrives mid-drain is now
  held and runs another pass as soon as the current one finishes.
