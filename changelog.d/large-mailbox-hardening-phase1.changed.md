- Two server-side efficiency changes from the large-mailbox hardening plan:
  the `/set_flag` Lambda no longer re-runs a full-folder IMAP `SORT` after
  every flag change (both the web and Apple clients discarded that UID list
  and re-polled for ordering anyway) and now acknowledges with
  `{"status": "submitted"}` like `/move_messages`; and every API Lambda's
  timeout drops from 30s to 29s to match API Gateway's integration ceiling,
  so a Lambda stops at the same boundary the client sees the request fail
  instead of billing on invisibly past it.
