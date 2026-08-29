- **Rules can set custom flags.** A mail rule can now tag arriving
  messages with the flags defined in Settings → Flags, both on a filing
  rule (the message lands in its folder already tagged) and on a
  decorate-then-file rule (a continuing rule's tags are carried to
  wherever the message ends up, custom flags included). Tagged
  deliveries go through Dovecot itself so per-folder keyword state
  stays consistent; a rule whose flag was deleted or disabled from the
  palette is skipped, like a rule whose folder is gone.
