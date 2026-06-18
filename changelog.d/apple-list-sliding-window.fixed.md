- Scrolling deep into a very large folder in the Apple clients no longer gets
  sluggish as more messages accumulate. The loaded message list is now a
  sliding window (~600 rows): paging down trims the scrolled-past front, and
  scrolling back up reloads it, so SwiftUI's per-update cost stays bounded no
  matter how far you scroll instead of growing with the loaded count. The
  scroll position is anchored by row id across each trim and reload so the
  viewport doesn't jump, and the top-page refresh resumes once you return to
  the top of the folder.
