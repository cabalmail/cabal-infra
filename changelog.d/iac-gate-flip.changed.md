- The Terraform IaC scanners (Checkov, tflint, Trivy) now **gate** deploys
  (IaC quality gates, Phase 3). A finding not in the stack's baseline / ignore
  list fails the scanner job and blocks the apply, where before it only
  surfaced in the Security tab. The accepted set is grandfathered per stack in
  `.checkov.baseline` / `.trivyignore` with a `BASELINE.md` rationale; a new
  resource that trips a rule fails CI until it is fixed or deliberately
  accepted. Tool versions are pinned (Checkov, tflint + its AWS ruleset, and
  the Trivy binary) so strictness changes only by a deliberate bump, and
  `make scan` reproduces the CI pass/fail verdict locally.
