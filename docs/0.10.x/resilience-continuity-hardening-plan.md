# Resilience and Continuity Hardening Plan

## Context

Cabalmail's backups, audit trails, and DNS-integrity story have grown additively. They are not absent — DynamoDB tables have PITR (most of them), EFS and DynamoDB are in an AWS Backup plan, S3 versioning is on the React-bundle and message-cache buckets — but the posture stops well short of "could survive a determined ransomware incident or an accidental admin destroy." This plan closes the headline gaps without proposing a multi-region active-active rebuild (which is its own initiative).

Five themes:

1. **Backup integrity.** The AWS Backup vault has no `aws_backup_vault_lock_configuration`. An admin who can call `aws backup delete-backup-vault` (which our deploy IAM principal can) can wipe the entire backup history. Backups are single-region and single-account: a regional outage or account compromise loses everything.
2. **DynamoDB completeness.** The `cabal-counter` table has neither PITR nor SSE explicitly. It is the source of truth for OS user IDs — wiping it would break IMAP/SMTP auth for every existing user.
3. **NLB and API audit trails.** No NLB access logs. API Gateway access logs exist but the per-tier mail traffic (993/587/465) has no equivalent. Incident investigation today is "read CloudWatch container logs, hope they captured what you need."
4. **DNS integrity.** Neither the control zone (`terraform/dns`) nor the mail-domain zones (`terraform/infra/modules/domains`) have DNSSEC. Mail-flow hijack via DNS spoofing — including downgrade of DMARC, MX, or BIMI records — has no on-protocol detection beyond client-side TLS at the SMTP layer.
5. **CloudFront posture.** Both CloudFront distributions (the admin app and the front-door) use legacy Origin Access Identity (OAI). The TLS policy is `TLSv1.2_2021`, two AWS-published policies behind current.

The plan ships in five phases. Phase 1 (backup hardening) is the highest-leverage because it raises the floor for every other failure mode. Phase 4 (DNSSEC) is the most operationally sensitive — DS records have to be added at the registrar, and a botched DS record is a self-inflicted DNS outage. Phase 4 goes last accordingly.

## Goals

- The AWS Backup vault is in Vault Lock governance mode with a minimum retention period of 30 days. A compromised admin cannot wipe backups inside the retention window.
- Backups copy to a second region (and ideally a second account) on the same schedule. A regional event or single-account compromise does not lose recovery capability.
- Every DynamoDB table has PITR enabled and explicit SSE. Tables holding identity-critical data (user_pool counter, addresses, user_domain_access) have `deletion_protection = true`.
- The NLB writes access logs to a versioned, lifecycled S3 bucket. Investigations can correlate per-IP per-port behaviour back six months without subpoenaing CloudWatch.
- DNSSEC is enabled on the control-domain zone and every mail-apex zone. Registrar DS records match. KSK rotation is documented and exercised.
- CloudFront distributions migrate from OAI to OAC. TLS minimum policy is `TLSv1.2_2023` or newer at the time of the PR. Both distributions front-door and admin keep functioning behaviour-identically.
- Operators have a written DR runbook that walks through "restore from yesterday's backup," "rebuild from the cross-region copy," and "manually rotate KSK on outage." All three are exercised against the development environment at least once.

## Non-goals

- Active-active multi-region. The data plane (Cognito, IMAP/SMTP) is single-region by design and this plan does not change that. A passive copy in another region is enough for the threat model.
- Switching from AWS Backup to a third-party backup tool (Veeam, Cohesity, etc.). AWS Backup is sufficient and our scale does not justify alternatives.
- Replacing CloudFront with a different CDN. The OAI→OAC migration is the right amount of churn for what it buys.
- Server-side encryption with customer-managed keys for every S3 bucket. Some buckets (Terraform state) are covered by [`state-encryption-plan.md`](./state-encryption-plan.md). Application buckets are covered situationally; full SSE-CMK uplift is its own posture decision.
- Domain registrar redundancy (registering each apex with two registrars). Out of scope.

## Current state (audit)

### Backups

[`terraform/infra/modules/backup/main.tf:5-10`](../../terraform/infra/modules/backup/main.tf):

```hcl
resource "aws_backup_vault" "backup" {
  name = "cabal-backup"
  lifecycle {
    prevent_destroy = false
  }
}
```

No `aws_backup_vault_lock_configuration`. The `prevent_destroy = false` setting allows Terraform to destroy the vault on apply if `var.backup` flips from `true` to `false`. The module docstring claims it "enforces `prevent_destroy`"; the code disagrees — a known doc-drift.

[`terraform/infra/modules/backup/main.tf:35-42`](../../terraform/infra/modules/backup/main.tf):

```hcl
resource "aws_backup_plan" "backup" {
  rule {
    rule_name         = "cabal-backup-plan-rule"
    target_vault_name = aws_backup_vault.backup.name
    schedule          = "cron(0 0 * * ? *)"
  }
}
```

No `copy_action`. No `lifecycle` (no defined retention or transition-to-cold-storage). The Backup Plan defaults to "keep forever," which is fine until billing is the issue or compliance demands deletion.

### DynamoDB completeness

Audit-relevant tables and their posture:

| Table                       | Defined in                                                                    | PITR | SSE   | Deletion protection |
| --------------------------- | ----------------------------------------------------------------------------- | ---- | ----- | ------------------- |
| `cabal-addresses`           | [`terraform/infra/modules/table/main.tf:6`](../../terraform/infra/modules/table/main.tf) | ✓    | ✓ (default key) | ✗ |
| `cabal-user-preferences`    | [`terraform/infra/modules/table/main.tf:30`](../../terraform/infra/modules/table/main.tf) | ✓    | ✓ (default key) | ✗ |
| `cabal-user-domain-access`  | [`terraform/infra/modules/table/main.tf:58`](../../terraform/infra/modules/table/main.tf) | ✓    | ✓ (default key) | ✗ |
| `cabal-counter`             | [`terraform/infra/modules/user_pool/counter.tf:135`](../../terraform/infra/modules/user_pool/counter.tf) | ✗    | ✗ (default-on bucket-level) | ✗ |
| `cabal-dmarc-reports`       | [`terraform/infra/modules/app/dmarc.tf`](../../terraform/infra/modules/app/dmarc.tf) | (verify) | (verify) | ✗ |

The counter table is the standout: it stores the auto-incrementing OS user ID. Wiping it would mean new signups collide with existing UIDs (because the counter restarts) and existing users lose mailbox association. PITR-restore is the only realistic recovery; without PITR, the entire user-pool→counter mapping has to be rebuilt by scanning Cognito attributes.

### NLB / API audit trails

[`terraform/infra/modules/elb/main.tf:5-14`](../../terraform/infra/modules/elb/main.tf):

```hcl
resource "aws_lb" "mail" {
  name               = "cabal-mail"
  internal           = false
  load_balancer_type = "network"
  ...
}
```

No `access_logs { ... }` block. Incident response for SMTP-IN abuse (spam delivery, brute-force) relies on container log lines, which are downstream of any NAT/proxy and lossy under pressure.

API Gateway access logs are configured in [`terraform/infra/modules/app/main.tf`](../../terraform/infra/modules/app/main.tf) and write to CloudWatch — that part is fine.

### DNS integrity

[`terraform/dns/main.tf:19-26`](../../terraform/dns/main.tf):

```hcl
resource "aws_route53_zone" "control" {
  name = var.control_domain
}
```

No DNSSEC. No KSK resource (`aws_route53_key_signing_key`), no `aws_route53_hosted_zone_dnssec`.

[`terraform/infra/modules/domains/main.tf:5-10`](../../terraform/infra/modules/domains/main.tf):

```hcl
resource "aws_route53_zone" "mail" {
  for_each = toset(var.mail_domains)
  name     = each.value
  force_destroy = true
}
```

Same — no DNSSEC. The `force_destroy = true` allows `terraform destroy` to nuke a mail zone with active records. A misclick on a destroy workflow loses the entire DNS history for that apex.

### CloudFront posture

[`terraform/infra/modules/app/cloudfront.tf:76`](../../terraform/infra/modules/app/cloudfront.tf) and [`terraform/infra/modules/front_door/main.tf:116`](../../terraform/infra/modules/front_door/main.tf): both set `minimum_protocol_version = "TLSv1.2_2021"`. AWS has released `TLSv1.2_2023` since.

[`terraform/infra/modules/s3/main.tf:20-22`](../../terraform/infra/modules/s3/main.tf) and [`terraform/infra/modules/app/cloudfront.tf:8-10`](../../terraform/infra/modules/app/cloudfront.tf): both use `aws_cloudfront_origin_access_identity` (OAI), the legacy mechanism. AWS recommends `aws_cloudfront_origin_access_control` (OAC), which supports SSE-KMS and avoids exposing the canonical-user shape in bucket policies.

## Target state

### Phase 1 — Backup vault lock + cross-region copy

[`terraform/infra/modules/backup/main.tf`](../../terraform/infra/modules/backup/main.tf) gains:

```hcl
resource "aws_backup_vault" "backup" {
  name = "cabal-backup"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_backup_vault_lock_configuration" "backup" {
  backup_vault_name   = aws_backup_vault.backup.name
  min_retention_days  = 30
  max_retention_days  = 365
  # changeable_for_days NOT set -> governance mode (admin can disable with one
  # extra API call, leaves audit trail). Compliance mode is one-way; we do
  # not need compliance mode for our threat model.
}

resource "aws_backup_vault" "backup_dr" {
  provider = aws.dr_region   # second region, configured at root
  name     = "cabal-backup-dr"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_backup_vault_lock_configuration" "backup_dr" {
  provider           = aws.dr_region
  backup_vault_name  = aws_backup_vault.backup_dr.name
  min_retention_days = 30
  max_retention_days = 365
}

resource "aws_backup_plan" "backup" {
  ...
  rule {
    rule_name         = "cabal-backup-plan-rule"
    target_vault_name = aws_backup_vault.backup.name
    schedule          = "cron(0 0 * * ? *)"

    lifecycle {
      cold_storage_after = 30
      delete_after       = 365
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.backup_dr.arn
      lifecycle {
        delete_after = 365
      }
    }
  }
}
```

The DR-region provider alias is added in [`terraform/infra/main.tf`](../../terraform/infra/main.tf):

```hcl
provider "aws" {
  alias  = "dr_region"
  region = var.dr_region   # defaults to "us-west-2" if primary is "us-east-1"
}
```

Governance mode means the deploy principal can call `DisableVaultLock` if needed (e.g., to legitimately destroy a dev environment), but the action shows up in CloudTrail with a 24-hour delay before deletion is allowed. That delay is the ransomware mitigation we are buying.

The fix to the docstring drift: update the module docstring to match the `prevent_destroy = true` reality.

Cross-account copy (the strongest ransomware mitigation) is deferred to a follow-up; setting up the second-account vault and its trust policy is a separate Phase 1.5 that depends on the cross-account IAM work flagged in [`identity-iam-hardening-plan.md`](./identity-iam-hardening-plan.md) Non-goals.

### Phase 2 — DynamoDB completeness

[`terraform/infra/modules/user_pool/counter.tf:135`](../../terraform/infra/modules/user_pool/counter.tf):

```hcl
resource "aws_dynamodb_table" "counter" {
  name                 = "cabal-counter"
  billing_mode         = "PAY_PER_REQUEST"
  hash_key             = "counter"
  deletion_protection_enabled = true

  attribute {
    name = "counter"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }
}
```

[`terraform/infra/modules/table/main.tf`](../../terraform/infra/modules/table/main.tf) and [`terraform/infra/modules/app/dmarc.tf`](../../terraform/infra/modules/app/dmarc.tf): `deletion_protection_enabled = true` on every table.

This is a small change but has an important rollback caveat: once `deletion_protection_enabled = true`, a Terraform plan to destroy the table fails until protection is disabled in a prior apply. That is the point.

### Phase 3 — NLB access logs

A small new S3 bucket for NLB logs:

```hcl
resource "aws_s3_bucket" "nlb_access_logs" {
  bucket = "cabal-nlb-access-logs-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "nlb_access_logs" {
  bucket = aws_s3_bucket.nlb_access_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "nlb_access_logs" {
  bucket = aws_s3_bucket.nlb_access_logs.id
  rule {
    id     = "expire-old"
    status = "Enabled"
    expiration {
      days = 180
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "nlb_access_logs" {
  bucket                  = aws_s3_bucket.nlb_access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "nlb_access_logs" {
  bucket = aws_s3_bucket.nlb_access_logs.id
  policy = data.aws_iam_policy_document.nlb_logs_policy.json
}
```

The bucket policy grants `s3:PutObject` to the regional ELB account ID (AWS publishes a per-region list; encode in a local).

[`terraform/infra/modules/elb/main.tf:5-14`](../../terraform/infra/modules/elb/main.tf):

```hcl
resource "aws_lb" "mail" {
  name               = "cabal-mail"
  internal           = false
  load_balancer_type = "network"
  ...

  access_logs {
    bucket  = aws_s3_bucket.nlb_access_logs.id
    enabled = true
    prefix  = "mail-nlb"
  }
}
```

NLB access logs land in S3 as gzipped log lines per-AZ-per-5-minute. Athena view over the bucket (created in Terraform) makes them queryable: `SELECT timestamp, client_ip, listener_port, action FROM mail_nlb_logs WHERE ...`.

### Phase 4 — DNSSEC

[`terraform/dns/main.tf`](../../terraform/dns/main.tf):

```hcl
resource "aws_kms_key" "dnssec" {
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 7
  key_usage                = "SIGN_VERIFY"

  policy = data.aws_iam_policy_document.dnssec_key_policy.json
}

resource "aws_kms_alias" "dnssec" {
  name          = "alias/cabal-dnssec-${var.environment}"
  target_key_id = aws_kms_key.dnssec.id
}

resource "aws_route53_key_signing_key" "control" {
  hosted_zone_id             = aws_route53_zone.control.id
  key_management_service_arn = aws_kms_key.dnssec.arn
  name                       = "cabal-${var.environment}-control"
}

resource "aws_route53_hosted_zone_dnssec" "control" {
  hosted_zone_id = aws_route53_zone.control.id

  depends_on = [aws_route53_key_signing_key.control]
}
```

Same pattern for each mail-domain zone in [`terraform/infra/modules/domains/main.tf`](../../terraform/infra/modules/domains/main.tf). The KSK is per-zone; the KMS key can be shared per environment.

`force_destroy` on the mail zones drops to `false`. The operator workflow for retiring a mail apex becomes "first delete records, then `terraform destroy` of just that zone." The `claude.md` runbook captures the procedure.

Registrar DS records: after `aws_route53_hosted_zone_dnssec` activates, Route 53 publishes a DS-record value (`ds_record`) as an output. The operator adds that DS record at the domain registrar. There is no Terraform-AWS-only path for this — the registrar is out-of-band.

Rollout sequence per zone (cribbed from AWS's documented DNSSEC enablement procedure):

1. Create KSK resource. Route 53 activates the KSK but does not yet sign.
2. Operator copies the published DS record value to the registrar.
3. Registrar publishes the DS record. Wait at least 24 hours for downstream resolver caches.
4. Apply `aws_route53_hosted_zone_dnssec` which sets `signing_status = "SIGNING"`. Zone now serves signed records.

The Terraform-driven sequence has to be two applies with manual operator action in between. The runbook captures this; the plan deliberately splits Phase 4 into Phase 4a (KSK creation, no signing) and Phase 4b (signing activation) accordingly.

KSK rotation cadence: yearly per AWS best practice. The KSK is a KMS-backed key, so rotation is mechanical; the DS record at the registrar has to update too. Document the rotation procedure in [`docs/operations.md`](../operations.md).

### Phase 5 — CloudFront OAI → OAC, TLS policy bump

[`terraform/infra/modules/app/cloudfront.tf`](../../terraform/infra/modules/app/cloudfront.tf) and [`terraform/infra/modules/front_door/main.tf`](../../terraform/infra/modules/front_door/main.tf):

```hcl
resource "aws_cloudfront_origin_access_control" "admin" {
  name                              = "cabal-admin-oac"
  description                       = "OAC for the admin app bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "admin" {
  ...
  origin {
    domain_name              = aws_s3_bucket.admin.bucket_regional_domain_name
    origin_id                = "admin-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.admin.id
    # remove `s3_origin_config { origin_access_identity = ... }`
  }

  viewer_certificate {
    acm_certificate_arn      = ...
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2023"   # was 2021
  }
}
```

S3 bucket policy on the admin bucket replaces the OAI canonical-user grant with an OAC SourceArn condition:

```hcl
data "aws_iam_policy_document" "admin_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.admin.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.admin.arn]
    }
  }
}
```

The migration is per-distribution. The OAI resources stay until the new bucket policy + OAC reference is in place; remove OAI in a follow-on apply once verified.

## Migration sequence

| Phase | Scope                                                                          | Reversible | Risk                                                                                                                                                                                          |
| ----- | ------------------------------------------------------------------------------ | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | Backup vault lock (governance mode), cross-region copy, plan retention         | Yes (vault lock can be disabled with 24 h delay)              | Low. Additive. New DR-region resources are cheap.                                                                                                                                              |
| 2     | DynamoDB PITR + SSE + deletion protection on counter; deletion_protection on others | Yes (flip the flag back, redeploy)                            | Low.                                                                                                                                                                                          |
| 3     | NLB access logs + S3 bucket                                                    | Yes                                                            | Low. Adds storage cost (small).                                                                                                                                                                |
| 4a    | DNSSEC: KSK creation (no signing)                                              | Yes (delete KSK resource before signing activation)            | Low.                                                                                                                                                                                          |
| 4b    | DNSSEC: signing activation (after registrar DS record published)               | Risky (zone has to roll back through "disabled" state with another delay)              | High. Botched DS record = self-inflicted DNS outage. Test in dev. Practice once before stage. Schedule outside production-critical windows.                                                                                                                                                                                                                          |
| 5     | CloudFront OAC + TLS policy bump                                               | Yes (revert OAI grant, restore policy)                         | Medium. Brief blip on the distribution-config rollout (Cloudfront propagation is 5-15 minutes). Schedule during low-traffic window.                                                              |

Per-environment ordering: dev → stage → prod for each phase. Phase 4 is the longest because of the wait-for-DS-propagation interlock.

## Rollback

- Phase 1: disable the vault lock (one-API-call, governance mode, takes effect after 24 h). Remove the `copy_action`. Drop the DR-region resources.
- Phase 2: set `deletion_protection_enabled = false` on each table; the PITR/SSE flags can stay (they are no-cost).
- Phase 3: remove the `access_logs` block on the NLB. The bucket can stay (cheap).
- Phase 4: this is the dangerous one.
  - 4a rollback: delete `aws_route53_key_signing_key`. Zone is unchanged.
  - 4b rollback: set `signing_status = "INACTIVE"` via `aws_route53_hosted_zone_dnssec`. Wait 24 hours for the previously-signed responses to age out of resolver caches. Then delete the DS record at the registrar. **Then** delete the KSK. Out-of-order rollback breaks resolution.
- Phase 5: restore the OAI shape in Terraform; OAC resources can stay attached but unused, or be deleted.

## CI changes

- [`.github/workflows/infra.yml`](../../.github/workflows/infra.yml) consumes a new `dr_region` provider; Terraform plan output gains the cross-region resources.
- [`terraform/infra/main.tf`](../../terraform/infra/main.tf) adds the `aws` provider with `alias = "dr_region"`.
- New variable `var.dr_region` (default `"us-west-2"`).
- New variable `var.dnssec_enabled` (default `true` once Phase 4 lands; false during the transitional period to allow per-environment opt-in).
- The Phase 4b registrar-update step lives outside of CI; capture it in [`docs/operations.md`](../operations.md).
- The Phase 5 OAI removal step is a two-apply sequence; capture the order in a comment in the Terraform file.

## Acceptance

- `aws backup describe-backup-vault --backup-vault-name cabal-backup` returns `LockDate: <future timestamp>` and `MinRetentionDays: 30`.
- `aws backup list-recovery-points-by-backup-vault --backup-vault-name cabal-backup-dr --region <dr_region>` shows recovery points from the last 24 hours.
- A `terraform destroy` against the prod environment refuses to drop `aws_dynamodb_table.counter` until `deletion_protection_enabled = false` is set in code.
- `aws s3 ls s3://cabal-nlb-access-logs-<account>/mail-nlb/AWSLogs/<account>/elasticloadbalancing/<region>/<yyyy>/<mm>/<dd>/` shows gzipped log objects from the last hour.
- An Athena query against the NLB-logs view returns rows.
- `dig +dnssec @<resolver> mail-admin.<first-apex>` shows the AD flag set and an RRSIG record alongside the answer.
- `whois <control-apex>` at the registrar shows a DS record matching `aws_route53_key_signing_key.control.ds_record`.
- `aws cloudfront get-distribution-config --id <admin-dist-id>` shows `OriginAccessControlId` set and no `OriginAccessIdentity`. `MinimumProtocolVersion: TLSv1.2_2023`.
- Browser `curl --tlsv1.2 https://admin.<control-domain>` succeeds; `curl --tlsv1.1` fails on protocol negotiation.
- A DR drill in development restores the message-cache S3 bucket from the previous day's backup; the restored mailbox opens in the React webmail with expected message counts.

## Open questions

- **Cross-account backup copy.** Phase 1 lands cross-region only. Cross-account is the stronger ransomware mitigation but requires a separate backup account and trust-policy setup; depends on the cross-account IAM work flagged in [`identity-iam-hardening-plan.md`](./identity-iam-hardening-plan.md). Schedule as Phase 1.5 once that work lands.
- **DNSSEC algorithm choice.** ECDSA P-256 (the default in `aws_kms_key.dnssec`) is supported broadly; RSA-SHA-256 is more universal but produces larger signatures. Recommendation: stick with ECDSA. Revisit only if we observe resolver-side compatibility issues.
- **NLB access-log retention window.** 180 days is the default the plan ships. Compliance-driven retention would push it longer (1-7 years for some regulated domains). Defer the decision until a compliance regime applies; bumping the lifecycle rule is a 1-line PR.
- **TLS 1.3 floor on CloudFront.** `TLSv1.2_2023` includes TLS 1.2 ciphers; a stricter `TLSv1.3` floor would lock out older clients. The webmail user base is modern browsers; the mail-protocol traffic does not go through CloudFront. Plausible to raise the floor in a follow-up.
- **Vault lock compliance mode vs governance mode.** Governance allows admin escape with audit trail and 24-hour delay; compliance is one-way for the retention period. The trade-off is "ransomware resistance" vs "fat-finger irreversibility." Recommendation: governance mode for the next 12 months; revisit annually.

## Out of scope for 0.10.x

- Cross-account backup copy.
- Multi-region active-active.
- Domain registrar redundancy.
- Per-bucket SSE-CMK uplift.
- GuardDuty / Security Hub / AWS Config recorder rollouts (worth a separate posture plan).
- Macie scanning of the message-cache bucket (sensitive-data classifier on user emails). Privacy-policy implications; defer.
