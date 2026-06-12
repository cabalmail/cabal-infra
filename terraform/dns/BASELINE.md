# terraform/dns - scanner baseline

Phase 2 of [`docs/0.10.x/iac-quality-gates-plan.md`](../../docs/0.10.x/iac-quality-gates-plan.md).

**Nearly clean.** tflint and Trivy report zero findings. Checkov (pip - the brew build omits graph checks, see `terraform/infra/BASELINE.md`) reports **2 graph findings** on the single Route 53 zone, both baselined:

| Tool    | Findings | Suppressed | Baselined |
| ------- | -------- | ---------- | --------- |
| Checkov | 2        | 0          | 2         |
| tflint  | 0        | 0          | 0         |
| Trivy   | 0        | 0          | 0         |

The two baselined Checkov findings on `aws_route53_zone.cabal_control_zone` are design-driven:

- **CKV2_AWS_38** - DNSSEC signing not enabled by default. Signing is now available behind `var.dnssec_enabled` (default false; resilience plan Phase 4, see `docs/dnssec.md`), but scanners evaluate variable defaults, so the zone still scans as unsigned and the entry stands until an environment-independent default flips.
- **CKV2_AWS_39** - DNS query logging not enabled. Deliberate cost choice, consistent with monitoring being off.

`dnssec.tf` (flag-gated, default off) carries inline, justified suppressions: **CKV_AWS_7** and **AVD-AWS-0065** on the KMS signing key (asymmetric signing keys do not support automatic KMS rotation; rotation is the manual KSK procedure in `docs/dnssec.md`), and `iam-wildcard-ok` on the key policy's `resources = ["*"]` entries (KMS key policies are self-referential - `"*"` means "this key" and no narrower form exists). The same suppressions appear in `terraform/infra/modules/domains/dnssec.tf`, this file's twin for the mail zones.

The companion files exist for parity with `terraform/infra` so CI and `make scan` treat both stacks identically:

- [`.checkov.yaml`](.checkov.yaml) - framework selection only; empty `skip-check`.
- [`.checkov.baseline`](.checkov.baseline) - the two findings above.
- [`.trivyignore`](.trivyignore) - header comment only, no ignored ids.

If a future change introduces a finding, classify it here as fix / suppress / baseline using the same scheme as `terraform/infra/BASELINE.md`.
