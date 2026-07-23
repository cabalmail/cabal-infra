- **Phantom subscription after folder delete.** Deleting a folder now also
  drops its IMAP subscription, so it no longer lingers in clients' Subscribed
  list. Unsubscribing also no longer selects the target mailbox first, so a
  stale subscription left behind by an earlier delete can be cleared instead
  of failing with a 502.
