- The admin app's `/list_envelopes` request timeout now scales with the
  batch size (number of UIDs requested) instead of using the flat 10s
  default, clamped to a 10s floor and a 30s ceiling. Large envelope
  batches no longer report a spurious "failed" while the server is still
  fetching.
