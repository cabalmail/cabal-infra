- Apple: **Siri-created addresses now actually reach the clipboard.** iOS
  silently refuses pasteboard writes from a backgrounded process, so the
  create-address intents' "copied to the clipboard" claim was false when
  invoked by voice. The intents now detect the failed write and offer a
  one-tap "Continue" hop into the app, where the copy completes; declining
  keeps the address in the spoken response and in the intent's Shortcuts
  output instead of pretending it was copied.
