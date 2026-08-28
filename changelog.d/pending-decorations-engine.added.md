- **Flag-then-file rule composition.** A rule with Flag and/or Mark as read,
  destination None, and Continue on now decorates the message instead of
  silently compiling to nothing: the marks ride per-message pending state in
  the rules engine and are applied wherever the message ends up — a later
  rule's destination folder or the inbox fallback. "Flag anything from
  billing" above "file receipts into Receipts" produces a flagged message in
  Receipts and nothing extra in the inbox. Rule sets without decorate-only
  rules compile byte-identically to before.
