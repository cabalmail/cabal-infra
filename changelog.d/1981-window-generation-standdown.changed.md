- **Stand-down coverage for the window re-read.** A folder-window re-read that
  lands after a reset has replaced the rows it was reading is now pinned by a
  regression test, and the bottom prefetch's equivalent check records why no
  test can reach it (its task is always cancelled first).
