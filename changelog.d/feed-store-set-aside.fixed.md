- Apple: **Unsent feed marks outlive a feed store that cannot be opened.**
  A feed store that was damaged, or was written by a newer build than
  the one installed, used to be deleted, and with it any read and flag
  marks that had not reached the server. It is now set aside, and the
  next build that can read it sends those marks. Signing out still
  removes everything, the set-aside copies included, and its wipe of the
  feed store now happens all at once or not at all.
