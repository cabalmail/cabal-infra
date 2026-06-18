- Deep-scrolling a large folder in the Apple clients is smoother and no longer
  degrades the further you scroll. Two causes were addressed: pagination now
  runs on a model-owned task instead of the scrolling row's SwiftUI `.task`, so
  a page that has started loading completes and merges even when the row that
  triggered it scrolls off-screen (rather than being cancelled as
  URLError.cancelled and retried); and the on-disk envelope snapshot, which is
  rewritten in full on each page (a write that grew with the loaded count), is
  now debounced off the pagination critical path so it persists once the scroll
  settles instead of stalling every page behind a growing write. The next page
  is also prefetched further ahead (the lookahead scales with the page size) so
  it is ready before the user reaches the end of the loaded rows.
