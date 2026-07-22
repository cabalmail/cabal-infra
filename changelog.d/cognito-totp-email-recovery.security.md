- The Cognito user pool now permits TOTP as an opt-in second factor
  (`mfa_configuration = "OPTIONAL"` with software-token MFA enabled), verifies
  email addresses supplied at signup, and offers account recovery by verified
  email ahead of SMS - a SIM swap alone can no longer take over an account
  with a verified email, and a lost phone is no longer a permanent lockout.
  Enrollment UX and sign-in challenge handling in the React and Apple clients
  ship separately; until then no user is enrolled and sign-in is unchanged.
