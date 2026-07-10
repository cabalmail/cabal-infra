- **Sent copies no longer silently stranded by a missing environment
  variable.** The `append_sent` consumer — the one Lambda defined outside the
  call module's shared environment block — never carried `CONTROL_DOMAIN`, so
  when the input-validation hardening switched every IMAP connection to the
  environment-derived host, the consumer began dialing the garbage name
  `imap.` and every Sent-copy append failed until the DLQ. glibc surfaced the
  bad name as an inscrutable `getaddrinfo` EBUSY rather than a resolution
  error, which sent the diagnosis down several wrong paths. The function's
  Terraform now sets `CONTROL_DOMAIN`, and `get_imap_client` fails loudly with
  the actual problem if any function ever reaches IMAP without it. SMTP
  delivery was never affected, and no Sent copy was lost — undelivered copies
  wait in the queue or DLQ with the raw message staged in S3, and can be
  redriven after deploy.
