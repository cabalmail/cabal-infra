- **Every remote-content vector in the web reader is now withheld until you
  load images.** Blocking previously covered only `<img src>`, so a message
  could still reach a tracking host through a CSS `background-image`, an
  `@import`, a `srcset`, or a `<video poster>` — and a message whose only
  remote references were in CSS showed no "remote images are blocked" banner
  at all, leaving no way to opt in. The reader document now carries a
  content-security policy that denies remote subresources outright, and the
  banner appears for all of those vectors.
