- The `master` service account (the identity the mail path uses for SMTP
  submission and IMAP master login) is no longer a member of the Cognito
  admin group. Nothing consumed that membership - submission auth is a bare
  password check and master never calls the admin API - so it was standing
  privilege, and as a headless account that can never enroll MFA it would
  have blocked admin-MFA enforcement: the audit-mode trigger flagged it on
  every outbound send. Least privilege and the enforcement flip both want it
  gone.
