- Dovecot now auto-creates the `Trash` mailbox (`auto = create` in
  `15-mailboxes.conf`) at namespace init, so it always exists before a
  mailbox's first delete. The `/move_messages` Lambda no longer force-creates
  `Trash` on every delete to cover that gap, dropping a wasted IMAP round
  trip from the delete path.
