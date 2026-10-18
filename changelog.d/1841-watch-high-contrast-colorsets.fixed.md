- **Unassignable watch high-contrast colour entries.** Every generated colour
  set carried a `(watch idiom, contrast high)` entry, and actool has no slot
  for that pair: the entry never drew anything and cost one "unassigned
  child" warning per colour set — 66 of them — on every build of
  CabalmailKit, on every platform. The generator no longer emits it; the
  watch still gets the dark value it has always drawn.
