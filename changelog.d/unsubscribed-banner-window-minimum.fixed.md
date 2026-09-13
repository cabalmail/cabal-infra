- Apple: **The unsubscribed-folder banner stops inflating the window.**
  Selecting Drafts, Sent or Trash on macOS grew the main window's minimum
  height to 973 pt, and the window then refused to shrink until a subscribed
  folder was selected again — on a display under about 1000 pt tall it no
  longer fit the screen. The banner sits in a bottom safe-area inset, so its
  height at the near-zero width AppKit proposes while sizing a window was the
  sentence wrapped to about one word per line. It is now bounded to the three
  lines it needs at the narrowest message-list column, so it reads exactly as
  before and asks the window for 54 pt instead of 731 pt.
