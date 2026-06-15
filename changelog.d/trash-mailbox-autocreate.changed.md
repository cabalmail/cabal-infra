- Dovecot now auto-creates the `Trash` mailbox (`auto = create` in
  `15-mailboxes.conf`) so a fresh mailbox has it before its first delete.
  Previously the `/move_messages` Lambda force-created `Trash` on every
  delete to cover the gap; moving that to Dovecot lets the Lambda stop
  paying that round trip once the behavior is confirmed in stage.
