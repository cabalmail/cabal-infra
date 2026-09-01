- **Sign-up detection on `/sign_up`-style URLs.** The detector's path
  vocabulary matched `signup` and `sign-up` but not the underscore spelling, so
  a page like `login.gov/sign_up/enter_email` — an email-only first step with
  no password field to score — fell into the ambiguous band and offered
  nothing. Both underscore variants are now recognized.
