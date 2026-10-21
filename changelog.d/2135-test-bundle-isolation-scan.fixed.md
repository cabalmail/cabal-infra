- **The macOS test bundle's concurrency ratchet covers the family it was
  added for.** `SWIFT_TREAT_WARNINGS_AS_ERRORS` promotes the grouped
  diagnostics but not the actor-isolation ones, which were 178 of the 248
  warnings the ratchet was added to keep out, and `-swift-version 6` on that
  target does not promote them either. A source scan pins the shape 165 of
  them took instead — an isolated suite overriding `setUp`/`tearDown`
  synchronously — and the setting's comment now says what it does and does
  not cover.
