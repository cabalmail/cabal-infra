# terraform/dns - scanner baseline

Phase 2 of [`docs/0.10.x/iac-quality-gates-plan.md`](../../docs/0.10.x/iac-quality-gates-plan.md).

**Nearly clean.** tflint and Trivy report zero findings. Checkov (pip - the brew build omits graph checks, see `terraform/infra/BASELINE.md`) reports **2 graph findings** on the single Route 53 zone, both baselined:

| Tool    | Findings | Suppressed | Baselined |
| ------- | -------- | ---------- | --------- |
| Checkov | 2        | 0          | 2         |
| tflint  | 0        | 0          | 0         |
| Trivy   | 0        | 0          | 0         |

The two baselined Checkov findings on `aws_route53_zone.cabal_control_zone` are design-driven:

- **CKV2_AWS_38** - DNSSEC signing not enabled. Not adopted for the control zone.
- **CKV2_AWS_39** - DNS query logging not enabled. Deliberate cost choice, consistent with monitoring being off.

The companion files exist for parity with `terraform/infra` so CI and `make scan` treat both stacks identically:

- [`.checkov.yaml`](.checkov.yaml) - framework selection only; empty `skip-check`.
- [`.checkov.baseline`](.checkov.baseline) - the two findings above.
- [`.trivyignore`](.trivyignore) - header comment only, no ignored ids.

If a future change introduces a finding, classify it here as fix / suppress / baseline using the same scheme as `terraform/infra/BASELINE.md`.
