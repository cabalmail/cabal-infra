- Fixed an iOS crash that could kill the app a second or two after you
  archived a message and sent the app to the background. The message
  list's per-row swipe actions were rebuilt with a lighter-weight
  implementation on iOS, iPadOS, and visionOS, so laying the list out for
  the background snapshot no longer risks the system watchdog. The macOS
  two-finger trackpad swipe is unchanged.
