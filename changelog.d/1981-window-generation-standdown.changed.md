- **Stand-down coverage for the window re-read.** A folder-window re-read that
  lands after a reset has replaced the rows it was reading is now pinned by a
  regression test, and two of the window's sibling checks record at the site
  why no test can reach them: the bottom prefetch's task is always cancelled
  first, and nothing suspends ahead of the one on a STATUS reading. The second
  is backed by a source scan that fails if that stops being true.
