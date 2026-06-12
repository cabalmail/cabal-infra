- A `force_tiers` input on the "Build and Deploy Application"
  workflow: a manual run still builds every docker tier in scope (the
  escape hatch for first deploys, base-image refreshes, and operator
  catchups), and `force_tiers=imap,smtp-out` narrows it to a named
  subset without needing a push that touches those tiers.
