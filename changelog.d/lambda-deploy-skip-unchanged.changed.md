- **Hash-aware Lambda API deploys.** The deploy step now fetches the
  deployed function inventory with a single `list-functions` call
  (replacing ~57 serial per-function probes) and skips any function
  whose freshly built zip is byte-identical to the running code, as
  judged by CodeSha256. A push no longer cold-starts the entire API
  surface by redeploying unchanged code, and the lambda-api job drops
  from roughly three minutes to about half that on a typical change.
