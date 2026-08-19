- Android: **Archive marks read; no duplicate moves.** Archiving (swipe,
  reader, bulk, search) now marks the message read in the same
  `/move_messages` call, as the Apple and React clients do — it was being
  moved unread. The swipe surface fired its action twice when a row was
  dragged all the way to its edge (foundation invokes `confirmValueChange`
  both as the drag ends and again from settle), and the view models accepted
  the repeat; Dovecot runs two concurrent MOVEs of one message
  independently, so the archive gained a duplicate copy, or the later MOVE
  failed with "Could not move message" after the first had already expunged
  the source. Swipes now fire once per gesture, and a move or purge already
  in flight for a UID drops any repeat request.
