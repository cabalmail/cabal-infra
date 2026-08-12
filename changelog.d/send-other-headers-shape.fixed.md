- **String-shaped threading headers no longer swallow later sends.** A
  `/send` or `/save_draft` payload carrying `other_headers.message_id` (or
  `in_reply_to`/`references`) as a bare string instead of a one-element list
  composed a Message-Id of the string's first character; `/send` then claimed
  that same character as its dedupe key for every such request, so each one
  after the first was silently discarded behind a `200 "submitted"`. The three
  threading fields now earn the same named 400 a bare-string `to_list` does.
