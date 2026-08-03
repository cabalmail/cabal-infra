- **Incomplete send payloads answered with a bodiless 502.** `/send` and
  `/save_draft` died on a `KeyError` when a request omitted the `message_id`,
  `in_reply_to`, or `references` entries of `other_headers` — the shape a
  fresh, non-reply compose produces — and again when it omitted any of
  `sender`, `subject`, `to_list`, `cc_list`, `bcc_list`, `text`, `html`, or
  `host`. The threading headers are now read as optional, matching the
  validator that already did; the rest are checked before anything indexes
  them and rejected with the 400 naming the missing field, which both
  endpoints already returned for a bad value.
