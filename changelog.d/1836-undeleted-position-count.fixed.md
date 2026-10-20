- Apple: **Message list stays lined up when mail is deleted elsewhere.** A
  message flagged `\Deleted` by another client, with no expunge behind it,
  leaves the set the server's list positions are numbered in while the folder's
  STATUS total still counts it. A window anchored on that total therefore saw
  no change at all, kept showing the row, and sat one position off from there
  down in any folder deeper than the loaded window. `/folder_status` now
  returns the not-deleted count alongside the flagged one, on the same opt-in
  and the same folder selection it already pays for, and everything in the list
  that treats the total as a position — the window anchor, the pagination gate,
  the top page's offset — reads that instead. The cheap status poll the badge
  and idle loops use is unchanged.
