# DNSSEC signing for the mail-domain zones (Phase 4 of
# docs/0.10.x/resilience-continuity-hardening-plan.md). Gated behind
# var.dnssec_enabled (default false) so each environment opts in
# deliberately. One shared KMS key signs every mail zone (KSKs are
# per-zone; the key is not); the control-domain zone is signed by the
# bootstrap stack's twin of this file (terraform/dns/dnssec.tf), which
# also covers the control domain when it doubles as a mail domain.
#
# Enablement ORDER MATTERS: flipping the flag turns on signing, which
# is safe on its own - no resolver validates until the registrar
# publishes a DS record per apex. Only after signing is verified does
# the operator add each zone's DS record at its registrar. Publishing
# DS first would SERVFAIL the domain on every validating resolver.
# Disabling reverses it: pull DS records, wait out resolver caches
# (24h+), then flip the flag off. Full runbook: docs/dnssec.md.

data "aws_caller_identity" "current" {}

# Asymmetric ECC_NIST_P256 signing key, required shape for Route 53
# DNSSEC. Must be in us-east-1 (provider alias). Automatic rotation
# does not exist for asymmetric KMS keys; rotation is the manual KSK
# procedure in docs/dnssec.md.
#checkov:skip=CKV_AWS_7:asymmetric signing keys do not support automatic rotation; rotation is the manual KSK procedure in docs/dnssec.md
#trivy:ignore:AVD-AWS-0065 # asymmetric signing keys do not support automatic rotation; rotation is the manual KSK procedure in docs/dnssec.md
resource "aws_kms_key" "dnssec" {
  count    = var.dnssec_enabled ? 1 : 0
  provider = aws.use1

  description              = "Signing key for DNSSEC on the cabal mail-domain zones"
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
  deletion_window_in_days  = 7

  policy = data.aws_iam_policy_document.dnssec_key_policy.json
}

resource "aws_kms_alias" "dnssec" {
  count    = var.dnssec_enabled ? 1 : 0
  provider = aws.use1

  name          = "alias/cabal-dnssec-mail"
  target_key_id = aws_kms_key.dnssec[0].key_id
}

# Key policy shape comes from the Route 53 DNSSEC docs: the
# dnssec-route53.amazonaws.com service principal needs DescribeKey /
# GetPublicKey / Sign plus CreateGrant (grants are how Route 53
# attaches each KSK), with aws:SourceAccount as the confused-deputy
# guard. KMS key policies are self-referential - "*" means "this key"
# - so the wildcard resource is the only valid spelling.
data "aws_iam_policy_document" "dnssec_key_policy" {
  statement {
    sid     = "AllowRoute53DnssecService"
    actions = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"]
    principals {
      type        = "Service"
      identifiers = ["dnssec-route53.amazonaws.com"]
    }
    # iam-wildcard-ok: KMS key policies have no narrower resource form; "*" is this key only
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:route53:::hostedzone/*"]
    }
  }

  statement {
    sid     = "AllowRoute53DnssecCreateGrant"
    actions = ["kms:CreateGrant"]
    principals {
      type        = "Service"
      identifiers = ["dnssec-route53.amazonaws.com"]
    }
    # iam-wildcard-ok: KMS key policies have no narrower resource form; "*" is this key only
    resources = ["*"]
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # Without an account-root statement the key would be unmanageable by
  # anyone, including the deploy principal that created it.
  statement {
    sid     = "EnableIamUserPermissions"
    actions = ["kms:*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    # iam-wildcard-ok: KMS key policies have no narrower resource form; "*" is this key only
    resources = ["*"]
  }
}

resource "aws_route53_key_signing_key" "mail" {
  for_each = toset(var.dnssec_enabled ? local.zone_domains : [])

  hosted_zone_id             = aws_route53_zone.mail_dns[each.key].id
  key_management_service_arn = aws_kms_key.dnssec[0].arn
  # KSK names allow only letters, digits, and underscores, and need
  # only be unique within their own zone.
  name = "cabal_mail_ksk"
}

resource "aws_route53_hosted_zone_dnssec" "mail" {
  for_each = toset(var.dnssec_enabled ? local.zone_domains : [])

  hosted_zone_id = aws_route53_zone.mail_dns[each.key].id

  depends_on = [aws_route53_key_signing_key.mail]
}
