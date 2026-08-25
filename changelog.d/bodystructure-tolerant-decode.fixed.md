- **Envelope decoding tolerates non-UTF-8 bytes in BODYSTRUCTURE.** A message
  whose MIME metadata carries raw 8-bit bytes (an unencoded Latin-1 attachment
  filename, for instance) failed the whole envelope page with a server error:
  one such message broke every `/search_envelopes` or `/list_envelopes`
  response whose page contained it, which surfaced as the Unread filter
  showing an empty list. Byte strings in a BODYSTRUCTURE now decode with a
  Latin-1 fallback instead of failing the request.
