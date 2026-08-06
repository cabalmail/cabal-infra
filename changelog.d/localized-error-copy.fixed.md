- Apple: **Errors read as sentences.** Failures surfaced the raw Swift enum,
  escaped JSON and all — a message deleted from another client showed
  `server(code: "404", message: "{\"status\": …")` across four red lines of
  the reader instead of "That message is no longer in Drafts." Every error
  now carries plain user-facing copy, preferring the server's own
  explanation where it sends one.
