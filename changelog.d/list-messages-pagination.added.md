- `/list_messages` now accepts optional `?offset=N&limit=M` query params and
  returns a `total` count alongside `message_ids`, so a client can fetch one
  page of a large folder and show "N of total" instead of pulling every UID
  (large-mailbox hardening, Layer 1.1). Dovecot `SORT` still orders the full
  result; the slice is positional (sort order, not UID order). With neither
  param set the response is the full sorted list as before, so existing clients
  are unaffected.
