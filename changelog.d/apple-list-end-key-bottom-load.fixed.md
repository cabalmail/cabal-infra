- Pressing End (or otherwise jumping to the bottom) of a large Apple folder
  now reliably loads the bottom messages instead of leaving them as
  placeholders forever. During the animated jump the rows swept past fired
  the window load first and claimed the single-flight reload slot for a
  mid-list position, so the destination rows' own load request bailed and
  the window never reached the bottom. Home / End now drive the destination
  window load explicitly, for the real target, before any row realizes, so
  those interlopers bail instead. End also clamps to the last actual message,
  since the row count can briefly run past the folder's reported total (a
  stale cache window) and a row beyond it can never be filled.
