- **Flag palette entry for the system flag.** `set_preferences` accepts a
  `\Flagged` entry in `flag_palette` beside the 20 keyword slots, so a
  palette holds up to 21 entries and the system flag can carry a label, a
  colour, a position and an enabled state like any other. The entry
  decorates the flag and gates nothing: `set_flag`, the rule compiler and
  every shipped client behave as before, and no client writes it yet. The
  palette validator gets its first unit tests. First phase of the
  unified-flags plan (`docs/1.x/unified-flags-plan.md`).
