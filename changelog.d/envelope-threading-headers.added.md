- `/list_envelopes` and `/search_envelopes` now emit `message_id`,
  `in_reply_to`, and `references` per envelope as lists of angle-bracketed
  ids (the `/fetch_message` wire shape), additively. References is capped
  at the newest 20 ids; the data prerequisite for conversation threading.
