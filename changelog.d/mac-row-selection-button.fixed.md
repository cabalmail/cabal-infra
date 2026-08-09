- Apple: **Clicking a message row selects it again on macOS 27.** The row's
  click target is now a button rather than a bare tap gesture, which macOS 27
  never delivered the click to — the reading pane stayed on "No message
  selected", no row highlighted, and the Message menu acted on nothing. The row
  also answers `AXPress` now, so VoiceOver and automation can activate it.
