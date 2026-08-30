- **Browser extension (initial implementation, not yet distributed).** A
  new `extensions/` workspace holds the address-suggesting extension for
  Chrome (MV3) and Safari: sign-up-form detection via a tunable scoring
  engine with a fixture corpus, 1Password-style suggest popover that
  eagerly creates the address while the form is being filled, an adopt flow
  for hand-typed addresses with a submit-time guard, Cognito Hosted UI +
  PKCE sign-in, and the private-window link handoff for the mail clients
  (redirector page at `https://admin.<control-domain>/private-link`).
  Store distribution and in-browser verification are still pending; see
  docs/1.x/browser-extension-plan.md for phase status.
