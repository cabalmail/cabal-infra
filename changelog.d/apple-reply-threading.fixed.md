- Replies from the Apple clients now carry In-Reply-To / References
  headers. The detail view threads from the fetched message's headers,
  envelopes decode the new threading fields, and `ReplyBuilder` prefers
  the original's real References chain per RFC 5322; message-ids are
  normalized to their angle-bracketed wire form at the submit seam.
