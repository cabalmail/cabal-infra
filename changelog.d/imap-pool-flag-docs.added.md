- Operator documentation for the `TF_VAR_IMAP_POOL_ENABLED` flag: an
  "IMAP connection pooling in the API Lambdas" section in
  `docs/operations.md` covering the default-off posture, how to enable it
  per environment, what pooling does on the request path (reuse,
  idle expiry, liveness probe, fail-fast, maintenance gate), and
  rollback, plus a matching entry in the `docs/github.md` variables
  reference.
