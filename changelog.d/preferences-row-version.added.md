- **A version on the synced-settings row, and a write that can say which
  version it was built on.** `set_preferences` counts every write to a
  user's settings, and `get_preferences` and each accepted write answer
  the count as `version`. A request may carry `expectedVersion`: when the
  row has moved on since, nothing is written and the answer is a 409
  holding the row as it is, for the client to merge and send again. A
  request without it is written as before, so builds in the field see no
  change; no client sends it yet. This is the server half of the fix for
  a device putting its older copy of the settings over the account's
  (#2452, #2464). The contract is in `docs/settings-sync.md`.
