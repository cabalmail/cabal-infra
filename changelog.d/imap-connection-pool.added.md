- Optional IMAP connection pooling in the API Lambdas (off by default,
  `IMAP_POOL_ENABLED` / `TF_VAR_IMAP_POOL_ENABLED`). When enabled, an
  authenticated master-user session is reused across warm invocations of the
  same execution environment instead of a fresh LOGIN/LOGOUT per request,
  keyed by `(host, user)`. Connections expire after an idle window and the
  mandatory re-SELECT on checkout doubles as a liveness probe (reconnect once
  on failure), so a socket left dead by a freeze/thaw or NAT eviction is
  discarded rather than reused. The flag-off path is unchanged. The pooling
  bookkeeping lives in a dependency-free `_shared/imap_pool.py` with stdlib
  unit tests.
