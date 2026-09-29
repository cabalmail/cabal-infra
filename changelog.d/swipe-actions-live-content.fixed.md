- Apple: **One row's swipe actions at a time, acting on the swiped
  message.** On iOS, iPadOS, macOS and visionOS 27 the message list's
  swipe actions come from the system's swipe-actions container again:
  revealing one row's actions retracts any other row's, and a tap on
  empty space or a scroll dismisses them. Unlike 1.22.2's attempt, each
  action now follows its row as it changes: read/unread flips with the
  message, and after the list shifts a swipe acts on the message the row
  shows. Earlier OS versions keep the previous behaviour, where each
  row's reveal is independent and stays put.
