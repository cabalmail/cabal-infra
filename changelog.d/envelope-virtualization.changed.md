- The web client's message list is now virtualized: it renders only the rows
  in (and just around) the viewport instead of every loaded envelope, so
  scroll smoothness and memory stay flat however deep into a large folder you
  go (large-mailbox hardening, Layer 2.2). The list pads itself top and bottom
  to stand in for the off-screen rows, and lazy page loading is now driven
  directly by scroll position.
