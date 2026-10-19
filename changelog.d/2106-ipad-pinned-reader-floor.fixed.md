- Apple: **iPad keeps its message list and toolbar after the addresses
  inspector.** Opening the Addresses inspector, composing from the message
  list's overflow menu and cancelling could leave the window with nothing but
  the reader's placeholder: no list column and no toolbar, so neither the
  folder list nor the inspector's own toggle was reachable without relaunching.
  The inspector tiles beside the split and takes its width out of it, which
  left the pinned list column and the reading pane's declared floor asking for
  more than the split had; the floor now yields to what the split has left
  wherever it cannot have all 360pt, so the layout the composer's dismissal
  re-resolves is one UIKit can still tile.
