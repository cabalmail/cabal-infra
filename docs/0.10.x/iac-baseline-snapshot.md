# IaC Baseline Snapshot (Phase 0)

This is the Phase 0 reconnaissance artifact for [`iac-quality-gates-plan.md`](./iac-quality-gates-plan.md). It records the finding counts and severity breakdown from running each scanner against both Terraform stacks on current `main`, so the size of the Phase 2.5 fix sweep and the eventual Phase 2 baseline are knowable rather than guessed. It touches no CI and changes no behaviour.

## Provenance

- **Measured against:** commit `371dc6a1` (branch `claude/eager-bose-f04a09`, branched from `main`; merge-base `31fa6e6c`).
- **Date:** 2026-06-07.
- **Tool versions:**
  - Checkov `3.2.530` (`--framework terraform`).
  - Trivy `0.71.0` (`trivy config`, i.e. IaC/misconfig scan).
  - tflint `0.63.1`, run with the **target** config the plan adopts in Phase 1, not the current broken one: bundled `terraform` ruleset `preset = "recommended"` plus the AWS ruleset at `0.40.0`. Measuring against the target config is what sizes the real baseline; the current CI config scans only the root dir of the infra stack (the broken `for i in ...; do tflint; done` loop never `cd`s) and pins the AWS ruleset at `0.20.0`, so its numbers are not representative.

Reproduce locally:

```sh
# DNS stack
checkov -d terraform/dns --framework terraform --compact --quiet
trivy config terraform/dns --quiet
TFLINT_CONFIG_FILE=<target.hcl> tflint --chdir=terraform/dns --recursive

# Infra stack
checkov -d terraform/infra --framework terraform --compact --quiet
trivy config terraform/infra --quiet
TFLINT_CONFIG_FILE=<target.hcl> tflint --chdir=terraform/infra --recursive
```

## Headline

| Stack            | Checkov (failed) | Trivy (total) | tflint (issues) |
| ---------------- | ---------------- | ------------- | --------------- |
| `terraform/dns`  | **0**            | **0**         | **0**           |
| `terraform/infra`| **200**          | **50**        | **6**           |

`terraform/dns` is clean across all three tools. This validates the plan's per-stack ordering (dns first through Phases 1-3): its Phase 2 baseline files will be empty and its gate can flip with zero remediation. The entire baselining and fix-sweep workload lives in `terraform/infra`.

## A note on severities

**Checkov's open-source CLI does not emit severities** (every finding comes back `UNKNOWN`); severity metadata requires a Prisma Cloud / Bridgecrew API key we do not have and the plan's non-goals do not call for. **Trivy does emit severities** for every finding. So Trivy is the severity-bearing tool, and the Phase 2.5 "HIGH/CRITICAL must-fix" gate and the Phase 3 severity-threshold decision should be driven off Trivy's classification. Checkov's value here is breadth of coverage, not triage.

This directly answers the plan's open question *"Severity threshold for fail vs. warn"*: a severity threshold is only meaningful for Trivy. Checkov and tflint are all-or-nothing (fail on any finding not in the baseline). Recommendation carried into Phase 3: gate Trivy on all severities (hygiene tool, not just a security tripwire), which is affordable because the LOW tier is the bulk and is overwhelmingly the "CMK instead of AWS-managed key" decay class (see below).

## `terraform/infra` - Checkov

`200` failed, `828` passed, `0` skipped, across `46` distinct check IDs. Top checks by count:

| Count | Check ID       | What it flags |
| ----- | -------------- | ------------- |
| 23 | CKV_AWS_338 | CloudWatch log group retention < 1 year |
| 23 | CKV_AWS_158 | CloudWatch log group not KMS-encrypted |
| 15 | CKV_AWS_337 | SSM parameters not using KMS CMK |
| 14 | CKV_AWS_136 | ECR repositories not KMS-encrypted |
| 13 | CKV_AWS_382 | Security group egress to 0.0.0.0/0 on all ports |
|  9 | CKV_AWS_50  | Lambda X-Ray tracing disabled |
|  9 | CKV_AWS_116 | Lambda has no DLQ |
|  9 | CKV_AWS_272 | Lambda code-signing not validated |
|  9 | CKV_AWS_115 | Lambda has no reserved-concurrency limit |
|  9 | CKV_AWS_336 | ECS containers not read-only root filesystem |
|  8 | CKV_AWS_117 | Lambda not in a VPC |
|  8 | CKV_AWS_173 | Lambda env vars not encrypted with CMK |
|  6 | CKV_AWS_119 | DynamoDB not encrypted with CMK |
|  3 | CKV_AWS_27  | SQS queue not encrypted |
|  3 | CKV_AWS_23  | Security group rule missing description |
|  2 | CKV_AWS_86  | CloudFront access logging disabled |
|  2 | CKV_AWS_68  | CloudFront has no WAF |
|  2 | CKV_AWS_310 | CloudFront has no origin failover |
|  2 | CKV_AWS_91  | ELBv2 access logging disabled |
|  2 | CKV_AWS_301 | Lambda publicly accessible (resource policy) |
|  2 | CKV_AWS_150 | Load balancer has no deletion protection |
|  2 | CKV_AWS_225 | API Gateway method caching disabled |

The remaining 24 check IDs are 1-2 hits each (full list in the raw scan). The bulk of Checkov's pile is the CMK/encryption-with-customer-managed-key and logging/retention classes - the plan's "medium/low, broad" decay bucket. Note a meaningful share of the Lambda/CloudFront/WAF findings are on `module.monitoring.*` resources, which are dormant in every environment (`TF_VAR_MONITORING=false`); static HCL analysis evaluates the module body regardless of the root `count` gate, so they appear here even though nothing instantiates them.

## `terraform/infra` - Trivy

`50` findings: **2 CRITICAL, 7 HIGH, 8 MEDIUM, 33 LOW**, across 18 distinct AVD IDs (the same `AWS-####`/`AVD-AWS-####` engine IDs the deprecated tfsec emitted, confirming the Trivy findings are a continuation of - and superset of - the prior tfsec coverage).

### HIGH / CRITICAL (Phase 2.5 must-fix candidates)

| Severity | Count | Trivy ID | Checkov equivalent | What |
| -------- | ----- | -------- | ------------------ | ---- |
| CRITICAL | 2 | AWS-0104 | CKV_AWS_382 (13x) | Security-group rule allows unrestricted egress to 0.0.0.0/0 |
| HIGH | 3 | AWS-0132 | CKV_AWS_136 (ECR) family | S3 encryption not using a Customer Managed Key |
| HIGH | 1 | AWS-0031 | CKV_AWS_51 | ECR image tags are mutable |
| HIGH | 1 | AWS-0095 | CKV_AWS_26 | SNS topic unencrypted (`module.ecs.aws_sns_topic.address_changed`) |
| HIGH | 1 | AWS-0096 | CKV_AWS_27 | SQS queue unencrypted (`module.ecs.aws_sqs_queue.tier[*]`) |
| HIGH | 1 | AWS-0131 | - | Instance with unencrypted block device |

That is **9 HIGH/CRITICAL findings across 6 distinct rules** - the low end of the plan's anticipated "5 to 40 fixes" range for Phase 2.5. Trivy and Checkov disagree on count for the same underlying issue (Trivy collapses the 13 egress rules into 2 CRITICAL findings; Checkov reports all 13) because they group findings differently; the *set* of underlying resources is the same.

### MEDIUM / LOW (decay candidates)

| Severity | Count | Trivy ID | What |
| -------- | ----- | -------- | ---- |
| MEDIUM | 3 | AWS-0090 | S3 bucket not versioned |
| MEDIUM | 3 | AWS-0320 | S3 bucket name not DNS-compliant |
| MEDIUM | 1 | AWS-0024 | DynamoDB point-in-time recovery disabled |
| MEDIUM | 1 | AWS-0178 | VPC flow logs disabled |
| LOW | 14 | AWS-0033 | ECR repo not using CMK |
| LOW | 7 | AWS-0017 | CloudWatch log group not using CMK |
| LOW | 3 | AWS-0089 | S3 bucket access logging disabled |
| LOW | 3 | AWS-0066 | Lambda X-Ray tracing disabled |
| LOW | 3 | AWS-0124 | Security group rule missing description |
| LOW | 1 | AWS-0003 | API Gateway X-Ray tracing disabled |
| LOW | 1 | AWS-0190 | API Gateway response caching disabled |
| LOW | 1 | AWS-0025 | DynamoDB not using CMK at rest |

The 33 LOW are dominated by "use a Customer Managed Key instead of an AWS-managed key" (AWS-0033, AWS-0017, AWS-0025 = 22 of 33). That is a deliberate cost/ops posture decision, not a vulnerability; it is the canonical "tool-of-no-use / design-driven" class and a strong candidate for a documented global or inline suppression rather than 22 KMS keys.

## `terraform/infra` - tflint

`6` issues, all `warning` severity, 2 distinct rules:

| Rule | Where |
| ---- | ----- |
| terraform_required_providers | `modules/app/global_dns.tf:11` - provider `tls` has no version constraint |
| terraform_unused_declarations | `modules/app/modules/call/lambda.tf:4` - `local.zip_file` unused |
| terraform_unused_declarations | `modules/app/modules/call/variables.tf:37` - var `relay_ips` unused |
| terraform_unused_declarations | `modules/app/modules/call/variables.tf:45` - var `repo` unused |
| terraform_unused_declarations | `modules/ecs/variables.tf:88` - var `master_password` unused |
| terraform_unused_declarations | `modules/elb/variables.tf:1` - var `vpc_id` unused |

All 6 are trivially fixable (delete the dead declarations, add a `tls` version pin) and should be **fixed outright in Phase 2.5**, not baselined - there is no reason to carry dead-code warnings in a baseline. The fact that the recommended preset surfaces only 6 lint issues across 122 `.tf` files is a good signal that the codebase is already close to the terraform-language rules.

## Implications for the plan

1. **Phase 2.5 is small and tractable.** 9 HIGH/CRITICAL Trivy findings (6 rules) + 6 tflint warnings. The plan's worry case ("hundreds rather than dozens") did not materialise; Phase 2.5 can stay a single pre-gate phase rather than splitting across point releases.
2. **The DNS stack needs no remediation.** Phases 1-3 for `terraform/dns` are pure CI plumbing; its baseline files are empty.
3. **Severity gating belongs to Trivy only** (Checkov CLI is severity-blind). Recommend Trivy gates on all severities, accepting that the ~33 LOW (mostly CMK-posture) get classified as documented suppressions in Phase 2 rather than fixes.
4. **The CMK class (~22 LOW + a large share of Checkov's 200) is the headline decay/suppress decision.** Whether Cabalmail adopts customer-managed KMS keys broadly is a posture call to make once during Phase 2 classification; the answer collapses a large fraction of both tools' piles either way.
5. **Checkov's 200 is breadth, not 200 distinct problems.** 46 check IDs, heavily weighted toward encryption-with-CMK, log retention, and Lambda hardening (much of it on the dormant monitoring module). Phase 2 classification should bucket by check ID, not by individual finding.
