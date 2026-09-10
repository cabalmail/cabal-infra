- **Feeds served only on `www`.** The canonical feed URL keeps the apex
  host (Decision 1), but some publishers answer the apex path with a 404
  or redirect every apex path to their front page, and only `www.` serves
  the feed. The fetcher and the subscribe probe now try the `www.` form
  once when the apex does not yield a feed, and a feed found there becomes
  the canonical URL. A permanent redirect from the apex form to the `www.`
  form of the same URL keeps `www.` instead of normalizing straight back.
  Found on the first OPML imports (2026-09-10).
