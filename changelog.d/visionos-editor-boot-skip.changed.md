- **Live-editor tests skip a visionOS editor that never loads.** The
  text-size and caret tests skip, rather than fail, on visionOS when the
  simulator's WebKit never finishes loading the editor page (#2252),
  which turned stage runs red at random; on every other platform it is
  still a failure.
