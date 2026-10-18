- Apple: **Folder total of 0 after a reload during an archive.** A message
  list that started over — the Refresh command's hard reload, or leaving a
  search — while one of its own removals was still in flight could show an
  All count of 0 and save 0 as the folder's total, which the next offline
  launch read. The reload clears the total until its refresh answers, and a
  server count that may predate the removal was being held to that cleared
  value; it is now held to the count the list showed when the reload
  started.
