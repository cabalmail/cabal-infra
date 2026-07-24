- MFA enrollment checking now covers every user, not only admins. The
  pre-token-generation trigger gains a second, independently-flagged gate
  (`TF_VAR_ENFORCE_USER_MFA`, audit-by-default like the admin gate) covering
  non-admin sign-ins, with a 48-hour grace window from account creation so
  new signups can enroll before it applies, and an explicit exemption for
  the password-only service accounts (SMTP submission, report ingest). After
  sign-in, users without an authenticator now see a skippable enrollment
  prompt that leads to the Security page - the funnel that gets accounts
  enrolled while the gate is still in audit.
