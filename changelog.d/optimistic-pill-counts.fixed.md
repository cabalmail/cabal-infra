- Apple: **Unread/Flagged filter-pill counts update instantly.** Flagging or
  reading a message (row swipe, reader toolbar, mark-as-read on open) updated
  the row's own indicators but left the All/Unread/Flagged pill counts stale
  until the next server refetch; the counts now follow every optimistic flag
  change (including bulk operations and error rollbacks) and still reconcile
  to server truth on refresh.
