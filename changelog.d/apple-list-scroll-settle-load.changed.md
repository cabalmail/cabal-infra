- After a scrollbar drag (or any jump) to an unloaded part of a large folder,
  the Apple message list now loads the now-visible window once scrolling
  settles, prefetching a page above and below. Previously, if a page load was
  already in flight when you landed, the new rows could sit as placeholders
  until you nudged the list again. The load is debounced to where you stop, so
  a fast drag fetches once at the destination rather than thrashing through the
  windows it passed.
