- Apple: **Address-picker no longer offers apex domains you can't mint on.**
  The macOS, iOS, visionOS, and watchOS new-address sheets now consult
  `/list_my_domains` and intersect the deployment's configured apexes with
  the caller's entitlement rows before populating the domain picker,
  matching the React admin app. Picking an unentitled apex and hitting
  Create used to surface an ugly HTTP 4xx from the `/new` Lambda; the
  unentitled apexes are now simply absent from the dropdown. The Lambda
  remains authoritative — a fetch failure falls back to showing every
  configured apex rather than an empty picker.
