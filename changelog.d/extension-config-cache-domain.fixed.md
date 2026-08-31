- **Extension config cache crossing environments.** The cached `config.json`
  was not scoped to the control domain it came from, so a bundle rebuilt
  against a different environment kept using the previous one's Cognito
  client for up to a day — sign-in then failed at the Hosted UI with
  `redirect_mismatch`, before any login form appeared.
