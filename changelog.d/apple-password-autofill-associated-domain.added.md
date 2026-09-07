- Apple: **Password managers can fill the one-time code.** The iOS and
  macOS apps now declare `admin.<control-domain>` as an associated
  domain, baked from `TF_VAR_CONTROL_DOMAIN` at build time, and the admin
  origin publishes the matching `apple-app-site-association` file once
  `TF_VAR_APPLE_TEAM_ID` is set. Password AutoFill and third-party
  managers such as 1Password can then match the native sign-in form to
  the login saved for the web app, including its verification code on
  the MFA step. Needs the Associated Domains capability on both App IDs;
  see `docs/password-autofill.md`.
