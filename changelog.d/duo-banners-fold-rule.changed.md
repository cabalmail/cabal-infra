- Apple: **Toasts and banners stay off the iPhone Duo's fold.** In book
  pose a toast now sits in the half of the window of the column that
  raised it, the reader's for the reader's own and for those that belong
  to the window (offline, a failed send, Resume), instead of across the
  crease. In laptop pose anything with a button or a close button stays
  below the fold and the offline banner sits above it. A toast records the
  window and column that raised it (`Toast.Origin`), and the placement is
  a pure rule over the window's bounds less the fold
  (`StatusBannerPlacement.slot(in:column:hasControls:)`). Nothing moves
  without a fold.
