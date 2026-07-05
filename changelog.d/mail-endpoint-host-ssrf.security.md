- The mail API no longer trusts the client-supplied `host`/`smtp_host`
  parameters. The IMAP/SMTP endpoints and the S3 cache bucket are now derived
  server-side from the environment's control domain, closing a path by which an
  authenticated user could aim a connection at a server they control and
  capture the shared IMAP/SMTP master credential.
