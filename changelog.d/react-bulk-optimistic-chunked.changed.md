- React webmail: bulk actions (archive, move, delete, mark read/unread,
  flag) now update the list optimistically -- the affected rows leave
  immediately and the counts reconcile from a folder STATUS poll instead
  of re-pulling the whole sorted UID list after every mutation; a failed
  request rolls the rows back. Each action also streams to the server in
  250-id chunks with an "Archiving N of M" progress affordance, so a
  multi-thousand-message selection no longer freezes the toolbar on one
  giant request.
