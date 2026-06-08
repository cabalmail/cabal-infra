# terraform/infra - scanner baseline

Phase 2 of [`docs/0.10.x/iac-quality-gates-plan.md`](../../docs/0.10.x/iac-quality-gates-plan.md). This file is the reviewed record behind the machine-readable suppression and baseline files in this directory. Every accepted finding is here with a rationale; decay candidates carry a target version.

Measured against commit `371dc6a1` (see [`docs/0.10.x/iac-baseline-snapshot.md`](../../docs/0.10.x/iac-baseline-snapshot.md) for the Phase 0 inventory). Gate posture: **fail on all Trivy severities** (Checkov is severity-blind, so it fails on any finding). The gate is still soft-fail until Phase 3.

## Files in this directory

| File | Purpose |
| ---- | ------- |
| [`.checkov.yaml`](.checkov.yaml) | Global, design-driven `skip-check` of the CMK class (11 ids). Policy only. |
| [`.checkov.baseline`](.checkov.baseline) | Per-resource grandfather of the 123 residual Checkov findings (31 ids). New findings fail. |
| [`.trivyignore`](.trivyignore) | Rule-id ignore list: the CMK class + design-driven + must-fix + decay (17 ids). |

## Counts

Updated after the Phase 2.5 safe batch (see [the safe-batch note](#phase-25-safe-batch-landed) below).

| Tool | Total (Phase 0) | CMK global-suppress | Baselined | Fixed / inline-suppressed (2.5) | Residual |
| ---- | --------------- | ------------------- | --------- | ------------------------------- | -------- |
| Checkov | 200 | 73 (11 ids) | 123 (31 ids) | 4 (CKV_AWS_276, _51 fixed; _111, _356 inline) | 0 |
| Trivy   | 50  | 25 (4 ids)  | 24 (13 ids) | 1 (AWS-0031 fixed) | 0 |
| tflint  | 6   | 0           | 0 (never baselined) | 1 fixed (`tls` version); 5 pending (unused decls) | 5 (next batch) |

Verified: `checkov -d terraform/infra --config-file .checkov.yaml --baseline .checkov.baseline` exits 0; `trivy config terraform/infra --ignorefile .trivyignore` reports 0 misconfigurations.

## 1. CMK class - global, permanent suppression

The single biggest cluster. Every flagged resource is **already encrypted at rest** with an AWS-managed or service-default key; these rules demand an upgrade to a customer-managed KMS key (CMK). A CMK buys key-policy control, a disable/delete kill switch, and separation of duties - benefits a single-operator system cannot meaningfully exploit - at $1/month/key plus request and operational cost. Cabalmail deliberately keeps AWS-default at-rest encryption. This is a posture decision, not a backlog item, so it is a global skip rather than a baseline entry implying "fix later".

If Cabalmail later adopts CMKs for the few data-plane secrets that would actually benefit (EFS mailstore, `cabal-addresses`, the IMAP master-password SSM parameter), drop the relevant id from `.checkov.yaml` / `.trivyignore` and let the check enforce.

- **Checkov** (`skip-check` in `.checkov.yaml`): CKV_AWS_158, CKV_AWS_337, CKV_AWS_136, CKV_AWS_119, CKV_AWS_173, CKV_AWS_297, CKV_AWS_166, CKV_AWS_184, CKV_AWS_180, CKV_AWS_200, CKV_AWS_199.
- **Trivy** (`.trivyignore`): AWS-0017, AWS-0025, AWS-0033, AWS-0132.

## 2. Must-fix in Phase 2.5

Genuine gaps that satisfy with a free AWS-managed/default key or a one-line attribute. Baselined now so the gate can flip cleanly; each Phase 2.5 PR removes the corresponding baseline/ignore entry so the gate then enforces the fix. **Target: clear before the Phase 3 gate flip.**

### Phase 2.5 safe batch (landed)

The low-risk, in-place subset shipped together:

- **CKV_AWS_276** - API Gateway `data_trace_enabled` set to `false` ([`modules/app/main.tf`](modules/app/main.tf)). It was logging full request/response bodies (addresses, message content, tokens) to CloudWatch.
- **CKV_AWS_51 / AWS-0031** - certbot ECR repo set `IMMUTABLE` ([`modules/certbot_renewal/ecr.tf`](modules/certbot_renewal/ecr.tf)), matching every other cabal repo.
- **tflint `terraform_required_providers`** - `tls` provider version pinned (`~> 4.0`) in [`modules/app/versions.tf`](modules/app/versions.tf).
- **CKV_AWS_111 / CKV_AWS_356** - reclassified to **inline design suppression** (`#checkov:skip` in [`modules/user_pool/variables.tf`](modules/user_pool/variables.tf)): the `sns_users` policy is Cognito SMS publish (`sns:Publish` to a phone number), which has no resource ARN to scope to, so `"*"` is required, not fixable. These leave the baseline.

### Still pending

| Checkov | Trivy | Resource(s) | Fix | Notes |
| ------- | ----- | ----------- | --- | ----- |
| CKV_AWS_26 | AWS-0095 | `aws_sns_topic.address_changed` | Encrypt with a KMS key (`alias/aws/sns`) | SNS has no managed-SSE option; the publisher + SNS->SQS path need `kms` perms. **Highest risk; stage-validate.** |
| CKV_AWS_27 (x3) | AWS-0096 | `aws_sqs_queue.tier[*]` | `sqs_managed_sse_enabled = true` | Message-flow sensitive (reconfiguration pipeline); SSE-SQS is transparent but stage-validate. |
| CKV_AWS_8 | AWS-0131 | NAT instance block device | `encrypted = true` | The custom AMI already encrypts; confirm `plan` does not force a NAT instance replacement (outbound blip). |
| - (tflint) | - | 5 `terraform_unused_declarations` | Remove dead vars/local | Check each call site first - a parent may pass `relay_ips`/`repo`/`master_password`/`vpc_id`. |

### Reclassified out of must-fix

- **CKV_AWS_341** - on `module.ecs.aws_launch_template.ecs` (the **ECS mail-tier** instances, *not* the NAT as first scoped), `http_put_response_hop_limit = 2`. Reducing to 1 risks breaking any mail container that reaches the host IMDS (vs. the task-role endpoint), on the cluster that runs the mail tiers. Left in the baseline pending stage validation that nothing relies on host IMDS at hop 2; if confirmed safe, reduce to 1, otherwise convert to an inline design suppression.

## 3. Design-driven - baselined, won't-fix

Accepted as intentional architecture. Baselined **per resource** (not globally skipped) so a *new* resource of the same kind is re-checked rather than silently allowed.

| Checkov | Trivy | Rationale |
| ------- | ----- | --------- |
| CKV_AWS_382 (x13) | AWS-0104 | Unrestricted egress - ECS tasks and the NAT instance need broad outbound (image pulls, DNS, SMTP delivery) |
| CKV_AWS_336 (x9) | - | ECS read-only root fs - the mail daemons (sendmail, dovecot, procmail) write to the container fs |
| CKV_AWS_117 (x8) | - | Lambdas intentionally not in a VPC (avoids NAT cost; they reach IMAP via the public NLB) |
| CKV_AWS_272 (x9) | - | Lambda code-signing not adopted (heavyweight for a solo deploy pipeline) |
| CKV_AWS_50, CKV_AWS_73 | AWS-0066, AWS-0003 | X-Ray tracing off - cost, consistent with monitoring being disabled everywhere |
| CKV_AWS_68, CKV_AWS_310, CKV_AWS_374 | - | CloudFront WAF / origin-failover / geo-restriction - cost and single-origin design |
| CKV_AWS_225, CKV_AWS_120, CKV_AWS_308 | AWS-0190 | API Gateway response caching undesirable for a mailbox API |
| CKV_AWS_126 | - | EC2 detailed monitoring off - cost |
| CKV_AWS_258, CKV_AWS_301 (x2) | - | Monitoring `alert_sink` Lambda URL - the monitoring tier is dormant (`TF_VAR_MONITORING=false` everywhere); revisit if it is ever enabled |
| CKV_AWS_338 (x23) | - | CloudWatch retention - see decay (candidate to set an explicit retention rather than accept) |
| CKV_AWS_330 | - | EFS access point user identity - mailstore needs specific uid/gid; revisit |
| - | AWS-0320 | S3 bucket names not DNS-compliant - names are stable identifiers; renaming is a data migration |
| - | AWS-0178 | VPC flow logs off - deliberate cost choice |

## 4. Decay - walk down over time

Low-value hygiene. Each release should clear or re-justify entries whose target version has arrived (Phase 4).

| Checkov | Trivy | Item | Target |
| ------- | ----- | ---- | ------ |
| CKV_AWS_338 (x23) | - | Set explicit CloudWatch log retention (also caps cost vs. never-expire) | 0.11.x |
| CKV_AWS_115 (x9) | - | Lambda reserved concurrency | 1.0.0 |
| CKV_AWS_116 (x9) | - | Lambda DLQ (where a dropped invoke matters) | 1.0.0 |
| CKV_AWS_86, CKV_AWS_91 | AWS-0089 | CloudFront / ELB / S3 access logging | 1.0.0 |
| CKV_AWS_150 (x2) | - | Load balancer deletion protection | 0.11.x |
| CKV_AWS_23 (x3) | AWS-0124 | Security group rule descriptions | 0.11.x |
| CKV_AWS_300 | - | S3 lifecycle: abort incomplete multipart uploads | 0.11.x |
| CKV_AWS_28 | AWS-0024 | DynamoDB PITR (note: `cabal-addresses` is also covered by AWS Backup when `backup=true`) | 1.0.0 |
| CKV_AWS_135 | AWS-0090 | EC2 EBS-optimized / S3 versioning | 1.0.0 |
| CKV_AWS_237 | - | API Gateway create-before-destroy lifecycle | 1.0.0 |

## Notes / known limitations

- **Trivy ignores by rule id, not per resource.** An id in `.trivyignore` is suppressed stack-wide, so a *new* resource violating an already-listed rule is not caught. Acceptable for this small, slow-changing stack; the must-fix ids are removed as Phase 2.5 lands, and the Phase 3 drift check flags any id here that no longer matches a real finding. If a specific rule needs per-resource precision, switch it to an inline `# trivy:ignore:<id> # reason` comment instead.
- **Classifications above are initial.** The fix/suppress boundary is sometimes only clear once a fix is attempted (per the plan); reclassify in the Phase 2.5 PRs as needed.
