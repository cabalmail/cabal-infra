- Apple: **Address rows swipe under a finger on a touch Mac.** A finger's
  swipe on an address row revealed nothing, though the trackpad's
  two-finger swipe did: the row's tap-to-copy was a `Button` filling the
  row, which kept the finger's swipe from the swipe actions. A tap gesture
  now copies (`rowTapAction`), and the row still reads to VoiceOver as one
  button whose activate copies. `RowTapActionTests` drives a click and an
  accessibility press through such a row in a `List`.
