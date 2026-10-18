- **Webmail Cognito JSON client.** `react/admin/src/auth/` speaks
  Cognito's JSON API directly, the way the Apple and Android kits do,
  ahead of dropping `amazon-cognito-identity-js` (end of support
  2027-03-01). It covers every operation the webmail uses: sign-up and
  confirmation, password sign-in with TOTP or SMS challenges, refresh,
  password reset, the recovery-email attributes and TOTP setup. It also
  includes a session holder that keeps only the refresh token, in
  sessionStorage, and refreshes single-flight. Its ID-token decoding
  handles base64url and UTF-8, which the `atob` read in `App.jsx`
  mishandles: it can throw on a claim holding `~`, `?` or `>`, and garbles
  non-ASCII text. Nothing calls the module yet; the sign-in screens move
  onto it in a follow-up.
