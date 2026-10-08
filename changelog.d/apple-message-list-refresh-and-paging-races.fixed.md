- Apple: **Message list refreshes and paging no longer race.** A new
  message no longer drops out of a small folder when two refreshes overlap
  (#1820). Folder messages no longer land among search or filter-pill
  results when a page was still loading as the search started (#1870). A
  folder whose server count runs high stops re-asking for the same empty
  page, and scrolling up from a scrollbar jump fills the rows just above
  first (#1823).
