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

Counts reflect **pip checkov** (what CI runs). See the [graph-check note](#graph-check-cohort-brew-to-pip-fix) below - the original `200 / 117` were generated with brew checkov, which silently omits the graph (`CKV2_*`) checks.

| Tool | Total | CMK global-suppress | Baselined | Fixed / inline-suppressed (2.5) | Residual |
| ---- | ----- | ------------------- | --------- | ------------------------------- | -------- |
| Checkov | 242 | 73 (11 ids) | 159 (51 ids) | 10 (276, 51, 8, 341, 26, 27x3 fixed; 111, 356 inline) | 0 |
| Trivy   | 50  | 26 (5 ids)  | 20 (10 ids) | 4 (AWS-0031, 0095, 0096, 0131 fixed) | 0 |
| tflint  | 6   | 0           | 0 (never baselined) | 6 fixed (`tls` version + 5 unused decls) | 0 |

Verified (pip checkov): `checkov -d terraform/infra --config-file .checkov.yaml --baseline .checkov.baseline` exits 0; `trivy config terraform/infra --ignorefile .trivyignore` reports 0 misconfigurations.

### Graph-check cohort (brew-to-pip fix)

The baselines were first generated with **brew** checkov, which omits the graph (`CKV2_*`) checks. CI runs **pip** checkov, which runs them, so on the gate's first live run 42 infra + 2 dns graph findings appeared as "new" and failed CI. Fixed by regenerating both baselines with pip checkov (matching CI) and adding a `checkov-graph-guard` to the Makefile so a brew checkov is caught locally. The 42 are pre-existing, mostly design/decay (WAF off, no DNSSEC/query-logging, S3 versioning/replication/lifecycle, CloudFront response-headers, API-GW request-validation, EFS-in-backup, monitoring-tier LBs which are dormant) - grandfathered.

Three are worth a follow-up review rather than permanent acceptance:

- **CKV_AWS_103 / CKV2_AWS_74** on `module.load_balancer.aws_lb_listener.imap` - the IMAP NLB's TLS policy / ciphers. Confirm it negotiates TLS 1.2+ with strong ciphers (real client-facing security; change with care for client compatibility).
- **CKV2_AWS_12** on `module.vpc.aws_vpc.network` - the VPC default security group is not locked down. A one-resource `aws_default_security_group` (deny-all) fix.
- **CKV_AWS_145** on the three S3 buckets (cache / front_door / bucket) - "encrypt with KMS by default." This is the same CMK posture we suppress elsewhere; candidate to move from the baseline to the `.checkov.yaml` CMK `skip-check` for consistency.

## 1. CMK class - global, permanent suppression

The single biggest cluster. Every flagged resource is **already encrypted at rest** with an AWS-managed or service-default key; these rules demand an upgrade to a customer-managed KMS key (CMK). A CMK buys key-policy control, a disable/delete kill switch, and separation of duties - benefits a single-operator system cannot meaningfully exploit - at $1/month/key plus request and operational cost. Cabalmail deliberately keeps AWS-default at-rest encryption. This is a posture decision, not a backlog item, so it is a global skip rather than a baseline entry implying "fix later".

If Cabalmail later adopts CMKs for the few data-plane secrets that would actually benefit (EFS mailstore, `cabal-addresses`, the IMAP master-password SSM parameter), drop the relevant id from `.checkov.yaml` / `.trivyignore` and let the check enforce.

- **Checkov** (`skip-check` in `.checkov.yaml`): CKV_AWS_158, CKV_AWS_337, CKV_AWS_136, CKV_AWS_119, CKV_AWS_173, CKV_AWS_297, CKV_AWS_166, CKV_AWS_184, CKV_AWS_180, CKV_AWS_200, CKV_AWS_199.
- **Trivy** (`.trivyignore`): AWS-0017, AWS-0025, AWS-0033, AWS-0132, AWS-0136 (SNS - it is encrypted with the `aws/sns` managed key; the check wants a CMK).

## 2. Must-fix in Phase 2.5

Genuine gaps that satisfy with a free AWS-managed/default key or a one-line attribute. Baselined now so the gate can flip cleanly; each Phase 2.5 PR removes the corresponding baseline/ignore entry so the gate then enforces the fix. **Target: clear before the Phase 3 gate flip.**

### Phase 2.5 safe batch (landed)

The low-risk, in-place subset shipped together:

- **CKV_AWS_276** - API Gateway `data_trace_enabled` set to `false` ([`modules/app/main.tf`](modules/app/main.tf)). It was logging full request/response bodies (addresses, message content, tokens) to CloudWatch.
- **CKV_AWS_51 / AWS-0031** - certbot ECR repo set `IMMUTABLE` ([`modules/certbot_renewal/ecr.tf`](modules/certbot_renewal/ecr.tf)), matching every other cabal repo.
- **tflint `terraform_required_providers`** - `tls` provider version pinned (`~> 4.0`) in [`modules/app/versions.tf`](modules/app/versions.tf).
- **CKV_AWS_111 / CKV_AWS_356** - reclassified to **inline design suppression** (`#checkov:skip` in [`modules/user_pool/variables.tf`](modules/user_pool/variables.tf)): the `sns_users` policy is Cognito SMS publish (`sns:Publish` to a phone number), which has no resource ARN to scope to, so `"*"` is required, not fixable. These leave the baseline.
- **tflint `terraform_unused_declarations` (the remaining 5)** - removed the dead declarations and their pass-throughs: `local.zip_file` and vars `relay_ips`/`repo` in the API-call submodule, `repo` in the app module, `master_password` in the ecs module (the password reaches containers via SSM `valueFrom`, never the variable), and `vpc_id` in the elb module (target groups live in the ecs module). Root `var.repo` stays (provider tags). Pure cleanup, no plan diff; `terraform validate` passes. **tflint is now at zero**, so its Phase 3 gate (drop the exit-2 swallow + `continue-on-error`) needs no further fix.

### Phase 2.5 remainder (landed - the message-flow / availability batch)

All fixed; each needs a stage-validation check on deploy (noted):

- **CKV_AWS_27 (x3) / AWS-0096** - `aws_sqs_queue.tier[*]` now set `sqs_managed_sse_enabled = true` (SSE-SQS). Transparent to SNS->SQS delivery and the reconfigure sidecar consumers.
- **CKV_AWS_26 / AWS-0095** - `aws_sns_topic.address_changed` now sets `kms_master_key_id = "alias/aws/sns"`. The publisher (new/revoke Lambda) gets `kms:GenerateDataKey`/`Decrypt` scoped via `kms:ViaService=sns` in [`modules/app/modules/call/lambda.tf`](modules/app/modules/call/lambda.tf). Encrypting with the managed (not customer) key moved the SNS finding to **AWS-0136**, now in the CMK suppression. **Stage-validate: publish a test address change and confirm the tier queues receive it / reconfigure fires.**
- **CKV_AWS_8 / AWS-0131** - the NAT instance now sets `root_block_device { encrypted = true }`. **Stage-validate: with the stock AMI this forces a NAT instance replacement (brief outbound blip).**
- **CKV_AWS_341** - resolved to **fix**: `module.ecs.aws_launch_template.ecs` IMDS `http_put_response_hop_limit` reduced 2 -> 1. Safe because the tasks run `awsvpc` and use the task-role credential endpoint, not the host IMDS. **Stage-validate: confirm the mail tiers stay healthy as instances cycle onto the new launch template.**

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
