- The Apple message list's Unread / Flagged filter pills now show every
  matching message in the folder, not just the ones already paged into
  memory. Tapping a pill runs a folder-scoped server search (the same
  `/search_envelopes` path the search bar uses) instead of filtering the
  loaded window, so flagged or unread mail scattered deep in a large folder
  surfaces immediately; All returns to the folder view. A pill is a fresh
  filter -- it replaces any text search, while the richer text-plus-flag
  combination stays available through the search filter sheet. The pill
  counts stay server-sourced, and when a folder has more matches than the
  fetched page the results banner discloses the "N of M" gap.
