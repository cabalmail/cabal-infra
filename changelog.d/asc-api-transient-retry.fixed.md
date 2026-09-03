- **A single App Store Connect hiccup no longer strands a TestFlight build.**
  The scripts that attach an upload to its TestFlight group and set its "What
  to Test" notes made every App Store Connect call without any retry, so one
  transient 500 from Apple failed the whole upload job — after the binary had
  already been accepted, leaving it on App Store Connect attached to no group
  and needing a manual fix-up. Those calls now retry a transient refusal (5xx
  or 429) a few times with backoff, honouring Apple's own `Retry-After` when
  it sends one. Only calls that a repeat cannot double are retried: reads
  always, and the two writes whose effect is the same however many times they
  land; creating the notes record is deliberately left alone.
