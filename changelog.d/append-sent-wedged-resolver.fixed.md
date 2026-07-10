- **Sent-copy delivery no longer trapped by a wedged sandbox resolver.** The
  `append_sent` consumer's Lambda sandboxes can wedge such that glibc DNS
  resolution of the IMAP host fails with `EBUSY` for the container's entire
  life, and because the SQS event source (batch size 1) pins redelivery to the
  same warm container, the Sent copy retried until the DLQ instead of being
  written. Only this consumer was exposed. It now resolves the IMAP host
  through a ladder — glibc first, a direct DNS query (dnspython) on `EBUSY`,
  and the address cached at INIT as the last resort — with the winning rung
  logged, and performs the first resolution at INIT so a sandbox wedged on
  every rung fails INIT and is replaced by Lambda. TLS certificate validation
  stays against the hostname throughout. SMTP delivery was never affected,
  and no Sent copy was lost — undelivered copies wait in the queue or DLQ
  with the raw message staged in S3.
