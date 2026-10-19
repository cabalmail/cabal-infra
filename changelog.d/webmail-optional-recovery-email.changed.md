- **Recovery email optional at sign-up when SMS is on.** So that
  Cabalmail can be someone's only email service, the webmail's sign-up
  form keeps the phone number required wherever the deployment can send
  texts and makes the recovery email optional there; without SMS the
  email stays required, since it is then the only way to verify or
  recover the account. After sign-in, an account with no email and a
  verified phone is no longer asked to add one when SMS is on, while an
  email that was given is still offered for verification. The Security
  view gains a recovery-email section to add, change or verify the
  address at any time, the only route for a phone-only account to add
  one later. `docs/auth.md` records the rule for every client.
