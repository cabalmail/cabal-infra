- Apple: **Swipe actions act on the swiped message again.** 1.22.2's
  one-row-at-a-time swipe actions kept each row's actions from when the
  row was first drawn: on macOS they appeared to do nothing, on iOS the
  read/unread action kept its old caption and effect, and after the list
  shifted a swipe could act on a different message. The message list is
  back on the previous swipe mechanism on every OS version, so more than
  one row can again show its actions at once.
