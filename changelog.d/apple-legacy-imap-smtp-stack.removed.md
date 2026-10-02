- Apple: **Direct IMAP and SMTP client code.** The hand-rolled IMAP and
  SMTP socket clients, their parser and connection layers, and the
  network-path monitor that only served them are gone, along with their
  tests (about 2,300 lines of source and 870 of tests). Mail has gone
  through the Cabalmail API since issue #371, so nothing in the app
  used them. The mail protocol interface also drops the connect,
  disconnect, append, single-part fetch, and UID-range calls that were
  no-ops or unused against the API, and three error cases only that
  code could raise.
