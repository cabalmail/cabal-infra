- **New folders are subscribed when they are created.** Dovecot does not
  subscribe on create, so a folder created from the web app never appeared in
  any client's subscribed list and was never fetched proactively — the native
  clients only avoided it by subscribing themselves afterwards. The API now
  subscribes what it creates, which pairs with folder deletion already
  unsubscribing what it removes.
