- Apple: **A queued message is no longer discarded when the server refuses to
  send it twice.** `/send` claims a Message-Id across the SMTP handoff, and the
  outbox re-submits its stored id on every drain. Any duplicate used to get the
  same `200 "submitted"` a real delivery gets, so the outbox deleted the queued
  message and logged it as sent - even when the claim was left behind by a
  submission that died before delivering anything, in which case the message
  was simply gone, with no error and no copy in Sent. `/send` now answers only
  a claim it can show delivered that way; one it cannot is a `409`, and the
  outbox holds the message until the claim clears instead of spending a retry
  on it.
