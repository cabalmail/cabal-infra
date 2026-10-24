- Apple: **Folder-qualified identifiers for search result rows.** A UID is
  unique only within one folder, so two unrelated messages in different
  folders could share one accessibility identifier in cross-folder search
  results, leaving one of the two rows with no identifier that addressed
  it. Rows on the global search surface are now
  `message.row.<folder>/<uid>`; folder lists, and a folder list's
  Unread/Flagged pills, keep `message.row.<uid>`.
