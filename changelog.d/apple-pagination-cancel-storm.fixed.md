- Fast-scrolling a large folder in the Apple clients no longer wastes and
  re-issues page fetches. Pagination now runs on a model-owned task instead of
  the scrolling row's SwiftUI `.task`, so a page that has started loading
  completes and merges even when the row that triggered it scrolls off-screen,
  rather than being cancelled (URLError.cancelled) and retried. Deep scrolling
  loads steadily instead of stalling until the user slows down.
