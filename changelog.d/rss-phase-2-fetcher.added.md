- **RSS feed fetcher (phase 2 of the RSS plan).** A five-minute EventBridge
  Scheduler tick (`rss_schedule`) claims due feeds from the `by_due` index
  and queues them; a bounded-concurrency worker (`rss_fetch`) does a
  conditional GET through an SSRF-guarded https-only client, parses
  RSS/Atom (feedparser) and JSON Feed (natively), upserts items, and
  records health and an adaptive per-feed cadence within operator bounds
  held in SSM (`/cabal/rss/cadence_{min,max}_minutes`). Publisher hints
  (`Cache-Control`, `Retry-After`, `<ttl>`, `sy:updatePeriod`) are honoured
  as floors; failures back off and dead-letter after twenty in a row;
  `410 Gone` dead-letters at once. The bot identifies itself as
  `Cabalmail-Feedbot/1` with a link to a new `feedbot.html` page on the
  front-door site. Quiesce now also pauses the tick. Nothing subscribes
  yet; the API follows in phase 3.
