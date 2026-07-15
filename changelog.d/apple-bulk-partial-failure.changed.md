- **Apple bulk actions now chunk large selections and report partial
  failures.** Flag and move operations go to the server in 1,000-message
  chunks as a timeout safety net, and when only some messages succeed the
  client keeps the ones that landed, restores the ones that failed, and
  shows "Moved X of Y" instead of silently losing rows.
