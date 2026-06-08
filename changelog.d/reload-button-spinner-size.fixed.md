- Reload buttons in the Apple clients no longer grow when they start
  refreshing. The message-list, folder-list, and address-list reload controls
  swap their `arrow.clockwise` glyph for a `ProgressView` spinner while the list
  updates, but the default spinner is larger than the glyph, so the button
  enlarged and shoved its neighbors aside - most visibly the message-list reload
  button displacing the adjacent New Message button. A new shared
  `RefreshActivityIcon` view (`apple/Cabalmail/Views/RefreshActivityIcon.swift`)
  keeps the glyph in the layout slot (hidden via opacity) and rides a
  `controlSize(.small)` spinner in an `overlay`, so the spinner can never feed
  back into the button's measured size; the footprint is now identical in both
  states. All seven reload sites across the iOS and macOS targets route through
  it, and the macOS in-list refresh rows keep their "Refresh" text visible
  instead of collapsing to a bare spinner.
