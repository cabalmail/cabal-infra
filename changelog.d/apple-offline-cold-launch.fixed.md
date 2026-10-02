- Apple: **Opening the app offline shows your cached mail.** A launch
  with no network used to land on the sign-in form, because the app
  fetched its server configuration before anything else and never kept a
  copy. It now remembers the last good configuration and, when the
  session can't be refreshed for lack of a connection, opens with the
  saved sign-in so the cached mailbox, Outbox and feeds stay readable
  until the network returns.
