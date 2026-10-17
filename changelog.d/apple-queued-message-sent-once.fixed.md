- Apple: **No second send of a delivered queued message.** When a message
  waiting in the outbox went out but its outbox copy couldn't be deleted,
  the app could send it again on a later retry; it now retries only the
  deletion. A relaunch or a new session still sends a copy left on disk
  once more, and the server's ten-minute duplicate check catches it when it
  comes soon after. An outbox that can't be read, and a draft whose copy on
  this device can't be saved, are now reported in the Debug Log instead of
  passing silently.
