- Bulk message operations are now chunked and bounded (large-mailbox
  hardening, Layer 1.3). `/move_messages` and `/set_flag` split a selection
  into 500-UID IMAP commands so one bulk action can't exceed the 29s API
  Gateway ceiling, report a `moved_ids`/`flagged_ids` plus `failed_ids` split
  when a batch fails partway instead of all-or-nothing, and answer `413` with
  `{"max_ids": 5000}` past the per-request cap. The React client refuses a bulk
  archive/move/delete/flag above 5,000 messages up front with a clear message
  rather than firing a request the server would reject.
