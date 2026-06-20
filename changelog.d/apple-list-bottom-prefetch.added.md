- The Apple message list now prefetches the bottom of a large folder in the
  background when it opens, so the first jump to the bottom (End, or dragging
  the scrollbar down) lands instantly instead of waiting on a fetch. Because
  the loaded window can't span both ends of a big folder at once, the bottom
  is staged in a small side buffer and adopted when a jump lands in it. The
  buffer is dropped whenever it could fall out of step with the folder -- a
  sort change, a folder reload, or any message leaving the folder -- and is
  only kept for folders larger than a single window.
