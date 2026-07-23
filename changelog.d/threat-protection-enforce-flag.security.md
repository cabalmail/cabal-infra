- Promoting Cognito threat protection from audit to enforced is now a
  per-environment variable (`TF_VAR_THREAT_PROTECTION_ENFORCED`) instead of a
  code change. The default remains audit: sign-in risk is scored and logged
  but never acted on. In enforced mode Cognito challenges risky sign-ins for
  MFA-enrolled users and blocks high-risk sign-ins outright, so flip it only
  once the risk metrics have soaked clean and TOTP enrollment is in place in
  that environment.
