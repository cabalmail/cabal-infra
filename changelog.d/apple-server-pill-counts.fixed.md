- The Apple clients' All / Unread / Flagged filter-pill counts now reflect
  the whole folder, sourced from the server (IMAP STATUS `messages`/`unseen`
  plus a new opt-in `?flagged=1` SEARCH FLAGGED count on `/folder_status`),
  instead of counting only the envelopes paged into memory. This matches the
  React webmail pills. During an active search the pills still count the
  loaded matches, since the folder totals don't apply to a result set. The
  flagged count is opt-in, so the inbox-badge and idle polls keep their
  cheap STATUS-only round trip.
