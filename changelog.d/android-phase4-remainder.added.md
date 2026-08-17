- **Android mail-reading interactions (Phase 4 remainder).** The message
  list gains All/Unread/Flagged filter pills with live `/folder_status`
  counts (patched locally as flags change), a sort menu (date received/
  date sent/sender/subject, either direction), swipe actions (toggle read,
  archive — or purge-with-confirmation in Trash), a long-press context
  menu, and bulk multi-select with a contextual action bar (read/unread,
  flag/unflag, move, dispose). Search arrives as a first-class cross-folder
  scope over `/search_envelopes` with a structured filter sheet and
  cursor paging; each result is labeled with, and operates on, its source
  folder. The reader adds To/Cc headers, SPF/DKIM/DMARC and priority
  chips, BIMI sender logos (colored-initials fallback, also in list rows),
  an Original/Reader render-mode toggle, inline `cid:` images resolved to
  data URIs, an attachment row that downloads via presigned URL and opens
  through a scoped FileProvider, and a move action. The folder list gets
  an Empty Trash action, and the cross-device resume cursor lands via
  `/get_nav_state` / `/set_nav_state`: same-install cursors restore
  silently on launch, foreign ones offer an opt-in "pick up where you
  left off" prompt.
