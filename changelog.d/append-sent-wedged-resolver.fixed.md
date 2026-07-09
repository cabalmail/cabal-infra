- **Sent-copy delivery no longer trapped by a wedged sandbox resolver.** When
  the `append_sent` consumer's Lambda execution environment hit a sticky
  `getaddrinfo` `EBUSY`, every invocation in that container failed identically
  and SQS pinned redelivery (batch size 1) to the same warm container, so the
  Sent copy retried until the DLQ instead of being written — even though a
  fresh container resolves the IMAP host fine. The consumer now crashes the
  process on that specific failure so Lambda retires the poisoned container and
  the next redelivery cold-starts a healthy one. SMTP delivery was never
  affected (it does not touch IMAP), and the planned-IMAP-roll retry path
  (`MaintenanceError`) is unchanged.
