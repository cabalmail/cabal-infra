- Apple clients: pull-to-refresh (and the background refresh) now clear
  stale rows after a folder shrinks below the loaded window - e.g. a bulk
  archive/move performed on another device. When the top-page fetch spans
  the whole (now-smaller) folder, any still-loaded message absent from it
  is pruned, so the list count reconciles with the filter-pill counts
  instead of stranding phantom rows until a hard reload.
