- Apple: **Column-resize handle detaches its pan recognizer on the main actor.**
  The iPad message-list resize coordinator removed its window-level gesture
  recognizer from `deinit`, which runs on whichever thread drops the last
  reference — a UIKit call with no main-thread guarantee. The teardown now
  hops to the main actor, so a coordinator released off the main thread can
  no longer leave a recognizer installed on a live window, where it would
  cancel drags anywhere in the app.
