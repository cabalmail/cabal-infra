- **User-defined mail rules (server side).** The IMAP tier now
  evaluates per-user mail rules on every incoming delivery, ahead of
  default delivery: conditions match From / To / Cc / Subject / Body
  (case-insensitive contains, ANDed), rules run in the user's chosen
  order, the first match fires, and each rule can opt into
  continue-to-next. Actions: move, copy, archive, and delete, plus
  the independent extras flag, mark as read, forward (loop-guarded,
  so a forward that routes back to the same mailbox is forwarded
  exactly once), and auto-reply (reply comes from the address the
  message was delivered to, marked per RFC 3834, with a 7-day
  per-sender suppression window and a 100-per-day cap). Rule sets are
  stored server-side with optimistic concurrency and a 90-day audit
  history, and are compiled to procmail with every user-supplied
  value escaped or the rule skipped - user input never lands as raw
  procmail syntax, and a rule that fails to compile never affects
  delivery of the message. BCC is deliberately not offered as a
  condition field: it is not present in delivered mail and would
  silently never match. Managed via the new `get_rules` /
  `set_rules` endpoints; the rule editors in the client apps ship
  separately.
