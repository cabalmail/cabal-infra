- Apple: **Queued mail that can't be sent is kept and shown, not dropped.**
  A message queued while offline used to be deleted after ten failed
  retries with nothing on screen, and a flapping connection could spend
  all ten in seconds. Retries now back off over time (30 seconds,
  doubling to an hour), and a message that still fails stays in the
  outbox with a banner offering Retry, or Discard / Keep for Later when
  you close it. Queued messages and local drafts that can't be read are
  moved aside to a quarantine folder instead of being deleted, and both
  are now stored with a schema version so a later update can migrate
  them rather than lose them.
