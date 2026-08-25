- **Reply from Sent addresses the recipients (web).** Same inversion as the
  native clients: replying to your own message in the Sent folder seeds From
  with the alias the original was sent from and targets the original To
  (plus Cc and Bcc on Reply All) instead of replying to yourself, without
  the spurious blind-copy warning. Serving this, `/list_envelopes` and
  `/search_envelopes` now expose a `bcc` field, populated for messages whose
  stored copy carries a Bcc header. A reply-seeded From the user no longer
  owns is cleared once the address list loads instead of wedging Send.
