- **Envelope fetches no longer fail when another session changes flags.**
  `/list_envelopes` returned a 502 (`KeyError: b'ENVELOPE'`) when an IMAP
  session changed flags on other messages in the same folder while envelopes
  were being fetched: the fetch response also carries the unsolicited `FLAGS`
  updates the server pushes, and those entries hold no envelope. Both envelope
  fetches — the message list's and cross-folder search's — now keep only the
  entries they asked for.
