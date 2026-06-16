- The Apple clients now paginate the message list positionally against the
  paginated `/list_messages` (large-mailbox hardening, Layer 3.1/3.3): the
  top page and every older page request a server-sliced `offset`/`limit`
  window instead of pulling the entire sorted UID list on every page. This
  also corrects paging under non-default sorts (the old UID-range window
  assumed UID order tracked the sort order) and removes the sparse-folder
  dead-end -- the client now stops paging when the loaded count reaches the
  folder's STATUS message total rather than walking a UID cursor down to 1.
  Older pages prefetch about half a page ahead of the scroll, so a moderate
  scroll no longer stalls at the bottom waiting for the next fetch.
