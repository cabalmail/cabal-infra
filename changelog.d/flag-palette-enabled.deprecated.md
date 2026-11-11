- **`enabled` on a flag palette entry.** `/set_preferences` still accepts
  and stores the field on an entry of the `flag_palette` preference, and
  nothing reads it any more. It stops being accepted in 2.0.0: from then
  an entry that carries it is refused, and the settings push with it.
  Clients should send entries as `{slot, label, color}`.
  `docs/compatibility.md` lists it under "Current deprecations", and
  `docs/2.x/flag-palette-enabled-removal.md` is the plan for the removal.
