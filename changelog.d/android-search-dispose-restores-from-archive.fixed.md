- Android: **Restore from Archive in Search.** A search result that lives in
  Archive had the defect the message list shed last release: with the Dispose
  action set to Archive its swipe was labelled Archive and moved the message
  onto Archive itself, marking it read, so the row vanished and the same
  search brought it straight back with its unread dot gone. Search results
  now resolve the dispose against each result's own folder, so the one in
  Archive says Restore and goes back to the inbox unread, and one in Trash
  still asks before purging.
