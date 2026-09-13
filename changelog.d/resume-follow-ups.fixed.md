- Apple: **Resume position holds up.** Reopening a half-read message or
  feed item now lands on the same paragraph rather than drifting as images
  load: the reader's scroll anchor named the page rather than an element
  whenever the reader styling's margin sat under the probe point, so it fell
  back to a fraction of the page height. A feed item reopened by the launch
  restore could sit on its spinner until backed out of and reopened; it
  loads directly now. On iPad, a window resize or Split View change that
  flips between the compact and regular layouts keeps the folder, message,
  or feed item that was open instead of jumping back to where the app
  launched (#1555). And the sidebar now highlights the folder a resume,
  push, Spotlight, or Siri navigation selected (#1535).
