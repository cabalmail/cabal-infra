- Apple clients: search now fetches its result set in bounded 50-envelope
  batches by walking the `/search_envelopes` cursor, instead of requesting
  the whole match set in a single call -- keeping each request small on
  wide, sparse searches. Multi-flag toggles also issue their per-flag
  `/set_flag` calls concurrently rather than one after another.
