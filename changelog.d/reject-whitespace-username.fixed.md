- New-address creation now rejects a local part (the text before the `@`)
  that is empty or contains any whitespace. A stray space rode into the
  generated sendmail `virtusertable`, where `makemap` rejects it and
  crash-loops the reconfigure sidecar — silently stopping *every* new address
  from propagating to the running mail tiers until the bad row was removed.
  `generate-config.sh` now also skips such a row defensively so one malformed
  entry can no longer wedge config regeneration for the whole fleet.
