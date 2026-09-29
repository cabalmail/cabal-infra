- Apple: **macOS column widths survive a relaunch.** The message list and
  the Addresses panel now open at the width they were last dragged to (the
  panel keeps it across closing and reopening, too), and the folder sidebar
  returns to within a point of where it was left rather than within 4pt. A
  list that a small window or the open Addresses panel was squeezing when
  the app quit still comes back at its dragged width. It used to come back
  at its minimum: on macOS 27, AppKit's own saved divider positions
  restored it short by the sidebar's width, so the app no longer uses them.
