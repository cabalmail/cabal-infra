- Admin sign-ins are now checked for MFA enrollment by a pre-token-generation
  trigger (`require_admin_mfa`). It ships in audit mode: an admin with no MFA
  factor is logged (a `would_block` line in the Lambda's log group) but not
  blocked. Setting `TF_VAR_ENFORCE_ADMIN_MFA=true` flips it to refuse token
  issuance for un-enrolled admins - only do this after every admin has
  enrolled an authenticator, since enrollment itself requires signing in.
  Non-admin sign-ins pass through untouched, and the trigger fails open on
  lookup errors so a Cognito hiccup cannot lock admins out of mail.
