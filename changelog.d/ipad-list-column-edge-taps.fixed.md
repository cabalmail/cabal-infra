- Apple: **Taps on the trailing edge of an iPad message row.** The drag handle
  that sizes the message-list column was a hit-testable strip, so the trailing
  22pt of every row — including part of the date and the `Select` glyph —
  silently swallowed taps and the row never opened. The handle now claims no
  touches of its own: a pan recognizer above the list begins only for a
  horizontal drag that starts at the column's edge, and everything else reaches
  the row.
