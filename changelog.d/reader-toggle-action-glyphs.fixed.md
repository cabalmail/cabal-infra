- Apple: **Reader toggle icons show the action, like their labels.** The mail
  reader's read button drew the message's current state (an open envelope
  beside "Mark as unread") while the feed reader's drew the action, and both
  readers' remote-content and reader-view buttons drew the current state
  beside a label naming the action. Every reader toggle now shows the action a
  press performs, as Gmail, Proton Mail and Apple Mail's action sheet do and as
  the app's own swipe actions, context menus and bulk bar already did: a read
  message shows the unread envelope, a message showing its remote content a
  slashed eye, a message in reader view the formatted-page glyph. The faces
  come from one shared definition (`ReaderToggleFace`), so the two readers and
  the macOS empty-pane placeholders can no longer drift apart.
