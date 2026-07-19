- **INBOX no longer presents as unsubscribed.** Dovecot's `namespace
  inbox` block now pins `mailbox INBOX { auto = subscribe }`, matching
  the pattern already used for `Archive`. Freshly-provisioned mailboxes
  and existing accounts whose subscription list had drifted are
  subscribed to INBOX on next access, so the Apple and web clients stop
  drawing the "not kept up-to-date" banner over the inbox itself.
