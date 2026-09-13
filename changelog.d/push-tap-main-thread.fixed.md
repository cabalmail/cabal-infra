- Apple: **Tapping a notification no longer crashes the app.** The system's
  completion handler for a notification action ran off the main thread, and
  UIKit's answer to it — refreshing the window scene's snapshot and
  state-restoration archive — asserts that it is on the main thread, so every
  tap on a banner aborted the app instead of opening the message.
