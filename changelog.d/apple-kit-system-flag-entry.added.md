- **Kit model for the system flag's palette entry.** `FlagPalette` in
  CabalmailKit learns the `\Flagged` entry the server now accepts: the
  effective palette (the stored one, with a default "Flagged" entry
  supplied first when it has none), the default flag (the first enabled
  entry), the rule that stores the entry only once the user has changed
  it, "reset to default", and message slots in palette order with the
  system flag included. `maxEntries` becomes 21. Nothing in the apps uses
  it yet, so nothing a user sees changes; Settings > Flags still counts
  the 20 flags a user can add. Second phase of the unified-flags plan
  (`docs/1.x/unified-flags-plan.md`), Apple half.
