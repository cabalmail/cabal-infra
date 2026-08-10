- Apple: **Reading pane could be squeezed out of the macOS window.** The
  message-list column declared no width of its own, so the split gave it what it
  asked for and charged its neighbours: the list froze at its launch width and
  the reading pane absorbed every resize alone, down to 60pt in a small window.
  A reader that narrow shows nothing, so selecting a message looked like it did
  nothing. The list now opens bounded and gives ground as the window shrinks, so
  the reader keeps a readable share at every window size.
