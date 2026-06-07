# terraform/infra - scanner baseline

Phase 2 of [`docs/0.10.x/iac-quality-gates-plan.md`](../../docs/0.10.x/iac-quality-gates-plan.md). This file is the reviewed record behind the machine-readable suppression and baseline files in this directory. Every accepted finding is here with a rationale; decay candidates carry a target version.

Measured against commit `371dc6a1` (see [`docs/0.10.x/iac-baseline-snapshot.md`](../../docs/0.10.x/iac-baseline-snapshot.md) for the Phase 0 inventory). Gate posture: **fail on all Trivy severities** (Checkov is severity-blind, so it fails on any finding). The gate is still soft-fail until Phase 3.

## Files in this directory

| File | Purpose |
| ---- | ------- |
| [`.checkov.yaml`](.checkov.yaml) | Global, design-driven `skip-check` of the CMK class (11 ids). Policy only. |
| [`.checkov.baseline`](.checkov.baseline) | Per-resource grandfather of the 127 residual Checkov findings (35 ids). New findings fail. |
| [`.trivyignore`](.trivyignore) | Rule-id ignore list: the CMK class + design-driven + must-fix + decay (18 ids). |

## Counts

| Tool | Total (Phase 0) | Globally suppressed (CMK) | Baselined / ignored | Residual after both |
| ---- | --------------- | ------------------------- | ------------------- | ------------------- |
| Checkov | 200 | 73 (11 ids, via `skip-check`) | 127 (35 ids, via baseline) | 0 |
| Trivy   | 50  | 25 (4 ids)  | 25 (14 ids) | 0 |
| tflint  | 6   | 0           | 0 (fixed in Phase 2.5, not baselined) | 0 after 2.5 |

Verified: `checkov -d terraform/infra --config-file .checkov.yaml --baseline .checkov.baseline` exits 0; `trivy config terraform/infra --ignorefile .trivyignore` reports 0 misconfigurations.

## 1. CMK class - global, permanent suppression

The single biggest cluster. Every flagged resource is **already encrypted at rest** with an AWS-managed or service-default key; these rules demand an upgrade to a customer-managed KMS key (CMK). A CMK buys key-policy control, a disable/delete kill switch, and separation of duties - benefits a single-operator system cannot meaningfully exploit - at $1/month/key plus request and operational cost. Cabalmail deliberately keeps AWS-default at-rest encryption. This is a posture decision, not a backlog item, so it is a global skip rather than a baseline entry implying "fix later".

If Cabalmail later adopts CMKs for the few data-plane secrets that would actually benefit (EFS mailstore, `cabal-addresses`, the IMAP master-password SSM parameter), drop the relevant id from `.checkov.yaml` / `.trivyignore` and let the check enforce.

- **Checkov** (`skip-check` in `.checkov.yaml`): CKV_AWS_158, CKV_AWS_337, CKV_AWS_136, CKV_AWS_119, CKV_AWS_173, CKV_AWS_297, CKV_AWS_166, CKV_AWS_184, CKV_AWS_180, CKV_AWS_200, CKV_AWS_199.
- **Trivy** (`.trivyignore`): AWS-0017, AWS-0025, AWS-0033, AWS-0132.

## 2. Must-fix in Phase 2.5

Genuine gaps that satisfy with a free AWS-managed/default key or a one-line attribute. Baselined now so the gate can flip cleanly; each Phase 2.5 PR removes the corresponding baseline/ignore entry so the gate then enforces the fix. **Target: clear before the Phase 3 gate flip.**

| Checkov | Trivy | Resource(s) | Fix |
| ------- | ----- | ----------- | --- |
| CKV_AWS_26 | AWS-0095 | `module.ecs.aws_sns_topic.address_changed` | Enable SSE with the `aws/sns` managed key |
| CKV_AWS_27 (x3) | AWS-0096 | `module.ecs.aws_sqs_queue.tier[*]` | Enable SSE-SQS. **Message-flow sensitive** (reconfiguration pipeline) - validate on stage |
| CKV_AWS_8 | AWS-0131 | NAT instance block device | Enable EBS encryption (free, default key) |
| CKV_AWS_51 | AWS-0031 | `module.certbot_renewal.aws_ecr_repository.certbot` | Set `image_tag_mutability = "IMMUTABLE"` (deploys use unique `sha-*` tags) |
| CKV_AWS_111 | - | `module.pool.aws_iam_policy_document.sns_users` | Constrain the write action |
| CKV_AWS_356 | - | `module.pool.aws_iam_policy_document.sns_users` | Replace `"*"` resource with the topic ARN |
| CKV_AWS_341 | - | NAT launch template | Set IMDS `http_put_response_hop_limit = 1` (SSRF hardening) |
| CKV_AWS_276 | - | API Gateway method settings | Confirm data-trace is intentionally off; flip if it is logging request/response data |

tflint's 6 warnings (5 unused declarations + 1 missing `tls` provider version) are also Phase 2.5 - fixed outright in code, never baselined.

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
