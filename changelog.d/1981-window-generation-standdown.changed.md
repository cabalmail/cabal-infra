- **Stand-down coverage for the window re-read.** A folder-window re-read that
  lands after a reset has replaced the rows it was reading is now pinned by a
  regression test, and the window's four sibling checks record at the site why
  no test can reach them: the bottom prefetch's task is always cancelled
  first, nothing suspends ahead of the one on a STATUS reading, and the two
  that answer a reset landing while a cache write is out have nothing to hold
  the caches at. The last three are backed by source scans that fail if those
  reasons stop holding.
