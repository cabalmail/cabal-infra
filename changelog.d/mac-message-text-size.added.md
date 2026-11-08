- Apple: **Text sizes on the Mac.** macOS has no Dynamic Type, so
  Settings > Appearance now has two sizes, each from Extra Small to Extra
  Large with Medium the size from before. Message text scales message
  bodies (HTML and plain text), feed articles in reader styling, and the
  composer; View > Larger Message Text (⌘+), Smaller Message Text (⌘−)
  and Default Message Text Size (⌘0) change it from any window. Interface
  text scales the app's own text everywhere else, each style keeping its
  size relative to the others, with the message list's rows growing to
  fit; menus and the toolbar stay the system's. Both are kept on the
  device rather than synced with the account (`AppTextSize`, `appFont`;
  the `raw_text_style_font` SwiftLint rule keeps raw text styles out).
