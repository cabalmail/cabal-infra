- Apple: **Feed read and favorite changes queue with the change itself.** The
  local flag and the push queued for the server committed separately, so a
  store write that failed in between left the item read (or favorited) on
  this device with nothing queued — the state sync only delivers rows the
  server changed, so nothing brought the two back together — or left an
  older, opposite change queued to be pushed over the latest tap. Both now
  happen in one transaction, as mark-all-read already did.
