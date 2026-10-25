- Apple: **iPad list floating over the reader after a Zoom.** Narrowing an
  iPad window to compact and zooming it back left the message list floating
  over a dimmed, full-width reader, with the reader's text running underneath
  it and no control to bring the list back. The split is rebuilt once when
  UIKit lays it out at an intermediate width during the zoom and so decides
  against tiling, and the message open in the reader carries across that
  rebuild.
