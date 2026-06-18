- The React webmail message list now polls `/folder_status` (a cheap IMAP
  STATUS round trip) every 10 seconds instead of re-pulling the entire
  sorted UID list, and only re-fetches that list when the folder actually
  changes - UIDNEXT advanced or the message count dropped - the same
  heuristic the Apple client uses. Steady-state poll cost on a large folder
  drops from proportional to the folder size to constant. The All / Unread /
  Flagged filter pills now show server-sourced counts (folder total, STATUS
  UNSEEN, and a new opt-in `?flagged=1` SEARCH count on `/folder_status`)
  rather than counting only the envelopes loaded so far.
