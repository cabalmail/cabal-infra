- **Blank push notifications from a truncated delivery.** A local delivery
  interrupted mid-write (the mail tier's periodic sendmail restart) can leave
  a zero-byte message file in the mailbox. `/push_envelope` treated the empty
  fetch as valid content, so every Apple device enriched its alert into empty
  title and body instead of the designed "New mail" fallback, and the empty
  bytes were written to the message cache, where they also made the message
  open blank forever after. Empty raw content is now treated as the message
  being gone: the endpoints answer 404, nothing is cached, and an
  already-poisoned cache entry is deleted and refetched on the next read.
  Relatedly, Message-IDs containing `/` (every GitHub notification) were
  failing the enrichment endpoint's validation and silently degrading to the
  wake signal's stale UID hint, which mis-targets enrichment during delivery
  bursts; a dedicated Message-ID validator now lets them resolve by search.
