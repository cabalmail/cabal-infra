- **Stored order for feed folders and All Feeds.** A feed folder now keeps
  the order its merged list opens in (`ordering_mode` on the folder, set
  through `/rss_update_folder`; folders created before this read newest
  first), and the All Feeds list keeps its order in the synced preference
  `order:feeds:all`. A folder's order applies to its own list only; the
  feeds inside keep theirs.
