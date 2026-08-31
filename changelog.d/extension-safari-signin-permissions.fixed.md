- **Safari sign-in in the browser extension.** The Hosted UI flow no longer
  waits on a promise that Safari can discard: the PKCE verifier is persisted
  for the duration of the flow and the background's redirect interception
  completes it, so sign-in survives the popup closing and the background
  worker being suspended. The popup now also asks Safari for the host
  permissions it needs (Safari grants those per site, not at install), and
  reports any failure instead of leaving the button looking inert — a
  config fetch that cannot reach the admin origin now times out with an
  explanation rather than hanging.
