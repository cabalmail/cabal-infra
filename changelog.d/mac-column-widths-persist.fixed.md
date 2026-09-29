- Apple: **macOS column widths survive a relaunch.** The message list and
  the Addresses panel now open at the width they were last dragged to (the
  panel keeps it across closing and reopening, too), and the folder sidebar
  returns to within a point of where it was left rather than within 4pt.
  The list used to come back at its minimum width: on macOS 27, AppKit's
  own saved divider positions restored it short by the sidebar's width, so
  the app no longer uses them.
