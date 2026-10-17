- Apple: **No second send of a delivered queued message.** When a message
  waiting in the outbox went out but its outbox copy couldn't be deleted,
  the app could send it again on a later retry; until the app is relaunched,
  it now retries only the deletion. An outbox that can't be read, and a
  draft whose copy on this device can't be saved, are now reported in the
  Debug Log instead of passing silently.
