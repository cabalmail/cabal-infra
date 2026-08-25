- Android: **Reliable rule auto-save.** Typing in the rules editor could
  cancel an in-flight save that the server had already committed, leaving
  the app behind the server's rule-set version; the next auto-save was then
  misreported as "Rules updated on another device", and Reload threw away
  the newer edits. The debounce timer and the save request are now
  independent, so a keystroke only resets the timer.
