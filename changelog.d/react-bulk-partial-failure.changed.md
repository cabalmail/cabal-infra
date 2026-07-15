- **Web bulk actions now report partial failures.** When the server
  completes a bulk move, archive, delete, or flag change for only some of
  the selected messages, the web app restores the rows that failed,
  keeps them selected for a one-click retry, and shows "Moved X of Y
  messages" instead of silently dropping them from view.
