- The Apple clients now wipe all locally cached mail when the user signs
  out: the on-disk envelope snapshots and message bodies, the local draft
  buffers, the outbox queue, and the in-memory address list are all cleared
  before the session is dropped. The caches live in a shared, non-user-scoped
  application-support directory, so previously a second account signing in on
  the same device could read the prior user's mail straight from disk without
  any re-fetch (and the outbox drain could even resubmit the prior user's
  queued messages under the new session).
