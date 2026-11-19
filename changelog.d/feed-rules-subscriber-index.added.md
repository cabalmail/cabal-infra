- **Subscriber lookup for feed rules.** `cabal-rss-subscription` gains a
  plain feed-keyed index, `by_feed`, and the `rss_fetch` worker's role
  gains what it needs to apply a subscriber's feed rules when it inserts
  an item: a query on that index, reads on `cabal-user-rules` and
  `cabal-user-preferences`, and updates on `cabal-rss-user-item-state`.
  Nothing uses them yet; the worker's code follows
  (docs/1.x/cross-media-ux-plan.md, Phase 4).
