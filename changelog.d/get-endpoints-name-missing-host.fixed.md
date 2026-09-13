- **Named 400 for a GET missing its `host` parameter.** `fetch_message`,
  `list_attachments`, `list_envelopes`, `list_folders` and `list_messages`
  indexed `host` without a presence check, so omitting it (or sending no query
  string at all) escaped as a bodiless `502 {"message": "Internal server
  error"}` with nothing for a client author to act on. They now answer
  `400 Invalid input: missing required parameter(s): host`, the same shape
  `/send` has returned since the equivalent fix for its JSON body.
