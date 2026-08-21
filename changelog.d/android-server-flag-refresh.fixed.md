- Android: **Flag changes from other clients land on refresh.** The message
  list served already-cached rows without re-fetching them, so a flag set or
  cleared elsewhere never reached the screen — a star cleared in another
  client survived pull-to-refresh (and app restarts) indefinitely. A cached
  band now paints only as a warm start while the row is re-fetched, and the
  server copy wins unless that row's own flag write is still in flight.
