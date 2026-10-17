- **Password reset keeps access to your mail.** Confirming a password reset
  also ran the step that gives a new account its system user id, so it could
  give an existing account a new id and leave its stored mail owned by the
  old one. A password reset no longer runs that step.
