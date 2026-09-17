- Apple: **iPhone stays compact in landscape.** On a Plus / Max iPhone,
  landscape reports a regular horizontal size class, and the Mail tab's
  split view expanded into tiled columns and collapsed again on the way
  back. After that cycle a tapped message could load into a reading pane
  that wasn't on screen (rotating to landscape revealed it), and the
  addresses inspector could surface as a full-height sheet over the tab
  bar with no way back but a force quit. The signed-in tab tree now pins
  the size class to compact on a phone, so the split view never expands
  and the inspector never changes presentation. Landscape on a Max shows
  the list or the reader full-width rather than side by side.
