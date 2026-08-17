- **Web app: the folder rail no longer opens in the previous account's
  shape.** Collapse state for the Subscribed and All folders sections, and
  for individual folders, is now stored per user rather than under one
  browser-wide key, so a second account signing in gets its own rail
  instead of inheriting the first account's collapsed sections. The old
  unscoped keys — which also held the previous account's folder names — are
  cleared at the next login or logout.
