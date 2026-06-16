- The admin web client no longer flashes a false "Unable to move/delete/flag"
  error on a large bulk operation that actually succeeds. Bulk IMAP mutations
  (move, set-flag, purge, empty-trash) now use a 30s request timeout that sits
  just above the API's 29s ceiling, instead of the 10s default that could fire
  before a chunked multi-thousand-message operation finished server-side.
