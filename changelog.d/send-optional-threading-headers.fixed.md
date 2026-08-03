- **Sending without threading headers.** `/send` and `/save_draft` failed
  with a bodiless 502 when a request omitted the `message_id`, `in_reply_to`,
  or `references` entries of `other_headers` — the shape a fresh, non-reply
  compose produces. The composer now reads them as optional, matching the
  validator that already did.
