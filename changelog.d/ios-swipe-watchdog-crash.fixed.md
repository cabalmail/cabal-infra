- Fixed an iOS crash that could kill the app a second or two after you
  archived a message and sent the app to the background. The message list
  now drops to lightweight placeholder rows while the app is backgrounded,
  so the system's background snapshot no longer has to lay out every row's
  swipe controls -- the work that could exceed the app's scene-update
  watchdog. The swipe gestures themselves are unchanged.
