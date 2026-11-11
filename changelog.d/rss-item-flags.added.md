- **Custom flags on feed items, server side.** `/rss_set_item_state`
  accepts `add_flags` and `remove_flags` per item: lists of the flag
  palette's keyword slots (`cabal-flag-01` .. `cabal-flag-20`), kept as a
  string set on the item's state row and changed one slot at a time, so
  two devices that change different flags of one item both take effect.
  Adding needs a slot the palette enables; removing does not, so a
  retired flag can still be cleared. A slot in both lists, the system
  flag (on a feed item that is `is_favorite`), or anything else that is
  not a slot is refused before anything is written. Items and state-sync
  rows from `/rss_list_items` and `/rss_get_item` carry `flags`, a sorted
  list. No client sends or reads them yet, and a request without the new
  fields is handled as before. First server PR of cross-media Phase 2
  (`docs/1.x/cross-media-ux-plan.md`).
