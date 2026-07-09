- **Sent-copy delivery no longer trapped by a wedged sandbox resolver.** The
  `append_sent` consumer's Lambda container can wedge such that DNS resolution
  of the IMAP host fails with `EBUSY` for the container's entire life, and
  because the SQS event source (batch size 1) pins redelivery to the same warm
  container, the Sent copy retried until the DLQ instead of being written.
  Only this consumer was exposed — interactive endpoints ride client retries
  onto other containers. The consumer now resolves the IMAP host once at INIT
  (so a container wedged from birth fails INIT and is replaced by Lambda) and
  falls back to that cached address if the resolver wedges later, keeping TLS
  certificate validation against the hostname. SMTP delivery was never
  affected, and no Sent copy was lost — undelivered copies wait in the queue
  or DLQ with the raw message staged in S3.
