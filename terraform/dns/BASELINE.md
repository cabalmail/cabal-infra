# terraform/dns - scanner baseline

Phase 2 of [`docs/0.10.x/iac-quality-gates-plan.md`](../../docs/0.10.x/iac-quality-gates-plan.md).

**Nearly clean.** tflint and Trivy report zero findings. Checkov (pip - the brew build omits graph checks, see `terraform/infra/BASELINE.md`) reports **1 graph finding** on the single Route 53 zone, baselined:

| Tool    | Findings | Suppressed | Baselined |
| ------- | -------- | ---------- | --------- |
| Checkov | 1        | 0          | 1         |
| tflint  | 0        | 0          | 0         |
| Trivy   | 0        | 0          | 0         |

The baselined Checkov finding on `aws_route53_zone.cabal_control_zone` is design-driven:

- **CKV2_AWS_39** - DNS query logging not enabled. Deliberate cost choice, consistent with monitoring being off.

**CKV2_AWS_38** (DNSSEC signing) cleared in 0.10.x: signing is available behind `var.dnssec_enabled` (resilience plan Phase 4, see `docs/dnssec.md`). The graph check connects the zone to the `aws_route53_hosted_zone_dnssec` resource without evaluating its count gate, so the check passes even while the flag defaults to false - the entry had to come out of the baseline to keep the drift check green. The real signing posture is per-environment (`TF_VAR_DNSSEC_ENABLED`).

`dnssec.tf` (flag-gated, default off) carries inline, justified suppressions: **CKV_AWS_7** and **AVD-AWS-0065** on the KMS signing key (asymmetric signing keys do not support automatic KMS rotation; rotation is the manual KSK procedure in `docs/dnssec.md`), and `iam-wildcard-ok` on the key policy's `resources = ["*"]` entries (KMS key policies are self-referential - `"*"` means "this key" and no narrower form exists). The same suppressions appear in `terraform/infra/modules/domains/dnssec.tf`, this file's twin for the mail zones.

The companion files exist for parity with `terraform/infra` so CI and `make scan` treat both stacks identically:

- [`.checkov.yaml`](.checkov.yaml) - framework selection only; empty `skip-check`.
- [`.checkov.baseline`](.checkov.baseline) - the two findings above.
- [`.trivyignore`](.trivyignore) - header comment only, no ignored ids.

If a future change introduces a finding, classify it here as fix / suppress / baseline using the same scheme as `terraform/infra/BASELINE.md`.
