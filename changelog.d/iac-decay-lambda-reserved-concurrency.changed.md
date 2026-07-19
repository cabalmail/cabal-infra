- **IaC decay: Lambda reserved-concurrency gate reclassified.**
  `CKV_AWS_115` (x9) moved from the scanner "decay" backlog to the
  design-driven baseline with no code change. All Lambdas deliberately
  share one account-wide concurrency pool; reserved concurrency both
  guarantees and caps, so it would either throttle the user-facing
  `api_call` hot path or carve burst capacity out from under it - the
  same rationale the two newest Lambdas (`push_dispatch`,
  `push_token_gc`) already carry as inline skips. Baseline entries stay
  per resource, so a new Lambda is still caught.
