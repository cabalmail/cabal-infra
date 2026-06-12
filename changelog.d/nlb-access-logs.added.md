- The mail NLB now writes access logs to a dedicated versioned S3
  bucket (`cabal-nlb-access-logs-<account>`, 180-day expiry), so
  incident response can correlate per-IP IMAPS connection behaviour
  months back instead of relying on container logs. NLB access logs
  cover TLS listeners only: that is the IMAPS listener (993); SMTP
  (25/465/587) is TCP passthrough and still relies on CloudWatch
  container logs. See docs/nlb-access-logs.md for the Athena query
  setup.
