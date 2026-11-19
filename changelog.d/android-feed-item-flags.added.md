- Android: **Your own flags on feed items.** Any flag in Settings > Flags
  can be set on a feed item: touch and hold its row for the menu, or use
  the feed reader's More menu. Rows draw a dot for each flag and the
  reader names them under the title, as for a message. The feed swipe and
  the feed reader's star now set and clear the default flag, as mail's
  do. A flag set offline is queued and sent later, and flags set on other
  devices arrive with the next sync. A flag the account no longer lists is
  taken off the item again; one created while Settings could not reach
  the server is sent first, so the item keeps it. The feed database moves
  to version 2 by its first real upgrade step, so unsent feed marks
  survive this update, where any schema change used to drop them; its
  schema is exported and the step is tested in CI. Queued feed changes are
  sent one batch at a time, in the order they were made.
