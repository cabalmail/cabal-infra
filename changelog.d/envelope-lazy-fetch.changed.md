- The web client's message list no longer fans out an envelope fetch for
  every page of a folder up front (and again on every 10s poll). It now
  lazily fetches the opening viewport and pulls further pages in as you
  scroll, refreshing only the already-loaded pages on each poll
  (large-mailbox hardening, Layer 2.1). Opening or polling a large folder
  drops from hundreds of parallel `/list_envelopes` requests to a handful.
