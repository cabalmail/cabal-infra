- **Extension's view of your existing addresses.** The browser extension read
  the address list in a shape the API never returns, so it silently believed
  every account had no addresses. Typing an address you already own therefore
  drew an offer to create it again, and the notice about reusing a subdomain
  could never appear. It now reads the real response, and a response it does
  not recognize is reported as an error rather than as an empty account.
