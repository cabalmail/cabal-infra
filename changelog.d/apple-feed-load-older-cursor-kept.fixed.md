- Apple: **"Load older items" no longer loses its place.** When a feed
  refreshed while older items were loading, the refresh could put back
  where "Load older items" had got to, so the next press fetched items
  already shown, or the button came back after the feed's history had run
  out. A refresh and a load of older items now each record only their own
  progress (#1938).
