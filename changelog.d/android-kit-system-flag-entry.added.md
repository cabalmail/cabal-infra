- **Android kit model for the system flag's palette entry.** `FlagPalette`
  in `android/kit` learns the `\Flagged` entry the server accepts since
  1.46.0, as CabalmailKit did in 1.47.0: the effective palette (the
  stored one, with a default "Flagged" entry supplied first when it has
  none), the default flag (the first enabled entry), the rule that stores
  the entry only once the user has changed it, "reset to default", and
  message slots in palette order with the system flag included.
  `MAX_ENTRIES` becomes 21; the keyword slots stay 20. Nothing in the app
  uses it yet, so nothing a user sees changes. Second phase of the
  unified-flags plan (`docs/1.x/unified-flags-plan.md`), Android half,
  and the first PR of android-parity.md leg L1.
