- Android: **Load older survives an overlapping sync.** A feed's sync and
  its "Load older items" each read the whole sync-state row when they
  started and wrote the whole thing back when they finished, so whichever
  landed second put the other's cursor back: the next load re-fetched the
  page it already had, and a feed loaded to the end of its history got its
  footer back with nothing behind it. Each write now touches only the
  cursors it owns.
