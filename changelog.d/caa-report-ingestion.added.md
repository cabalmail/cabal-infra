- **CAA violation reports on the admin site.** The CAA `iodef` contact is a
  new system-managed address, `caa-reports@mail-admin.<first mail domain>`,
  delivered to the same mailbox as DMARC reports. The `process_dmarc` Lambda
  ingests these messages into a new `cabal-caa-reports` table (raw message
  archived to S3), and a new admin-only CAA view lists them, following the
  DMARC-report pattern. The view is expected to stay empty: a CA sends an
  iodef report only when it refuses a certificate request that violates the
  CAA policy, so any row is a mis-issuance attempt (or deliberate test) worth
  investigating.
