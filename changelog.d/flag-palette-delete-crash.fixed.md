- Apple: **Deleting a custom flag no longer quits the app.** Confirming
  "Delete Flag" in Settings ▸ Flags terminated the app outright and lost the
  deletion — the palette still held the flag on the next launch — whenever
  the flag was the last one in the list, which is every flag just added and
  the only flag in a one-flag palette. The editor addressed its entry by
  position, so the Name field and Enabled toggle read past the end of the
  shortened palette while they were still on screen. Every read and write in
  the editor now addresses the flag by its slot and copes with the flag
  being gone, including when another device deletes it mid-edit.
