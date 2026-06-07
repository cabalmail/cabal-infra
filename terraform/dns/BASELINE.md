# terraform/dns - scanner baseline

Phase 2 of [`docs/0.10.x/iac-quality-gates-plan.md`](../../docs/0.10.x/iac-quality-gates-plan.md).

**The bootstrap stack is clean.** As of the Phase 0 snapshot (commit `371dc6a1`), Checkov, tflint, and Trivy all report **zero findings** against `terraform/dns`. There are no suppressions and no baselined findings.

| Tool    | Findings | Suppressed | Baselined |
| ------- | -------- | ---------- | --------- |
| Checkov | 0        | 0          | 0         |
| tflint  | 0        | 0          | 0         |
| Trivy   | 0        | 0          | 0         |

The companion files in this directory exist for parity with `terraform/infra` so CI and `make scan` treat both stacks identically:

- [`.checkov.yaml`](.checkov.yaml) - framework selection only; empty `skip-check`.
- [`.checkov.baseline`](.checkov.baseline) - `{"failed_checks": []}`.
- [`.trivyignore`](.trivyignore) - header comment only, no ignored ids.

This stack can have its gate flipped (Phase 3) with no remediation work. If a future change introduces a finding, classify it here as fix / suppress / baseline using the same scheme as `terraform/infra/BASELINE.md`.
