- **Extra inbox copies from flag-tagging rules.** A rule that tags a
  message with a custom flag delivered the tagged message correctly but
  also left an extra untagged copy in the inbox: the delivery helper
  could not remove the append drain's root-owned response file from the
  sticky spool, misread its own success as a failure, and fell through
  to an additional delivery. The drain now hands the response file to
  the requesting user, and the helper treats response collection as
  best-effort.
