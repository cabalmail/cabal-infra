# NLB access logs (Phase 3 of
# docs/0.10.x/resilience-continuity-hardening-plan.md).
#
# IMPORTANT CAVEAT: NLB access logs are produced for TLS listeners
# ONLY. On this load balancer that is the IMAPS listener (993); the
# SMTP listeners (25, 465, 587) are TCP passthrough - TLS terminates
# in sendmail/Dovecot inside the containers - so their traffic never
# appears here and incident response for SMTP abuse still relies on
# container logs in CloudWatch. Moving 465/587 to TLS listeners would
# change the data plane (cert ownership, client-visible handshake) and
# is out of scope here.
#
# Logs land as gzipped objects under
# s3://cabal-nlb-access-logs-<account>/mail-nlb/AWSLogs/<account>/...
# one file per LB node per 5 minutes. docs/nlb-access-logs.md has an
# Athena DDL for querying them.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Logging the log bucket into itself would recurse, and a second
# bucket for meta-logs is not worth it for operational TLS-connection
# records; replication is likewise skipped because the logs expire in
# 180 days and exist for incident response, not durability.
#checkov:skip=CKV_AWS_18:access-logging the access-log bucket recurses; meta-logs not worth a second bucket
#checkov:skip=CKV_AWS_144:operational logs with 180-day expiry; cross-region replication buys nothing
#checkov:skip=CKV2_AWS_62:no consumer for object-created events on a log bucket
resource "aws_s3_bucket" "nlb_access_logs" {
  bucket = "cabal-nlb-access-logs-${data.aws_caller_identity.current.account_id}"
}

# Versioning protects delivered log objects from silent overwrite or
# deletion (an attacker scrubbing their tracks needs to also purge
# noncurrent versions, which the lifecycle below only does after 30
# days).
resource "aws_s3_bucket_versioning" "nlb_access_logs" {
  bucket = aws_s3_bucket.nlb_access_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3, not SSE-KMS: NLB log delivery does not support the
# AWS-managed KMS key, and the repo's posture (see BASELINE.md, CMK
# class) deliberately avoids customer-managed keys.
resource "aws_s3_bucket_server_side_encryption_configuration" "nlb_access_logs" {
  bucket = aws_s3_bucket.nlb_access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 180-day retention: long enough to correlate per-IP behaviour across
# months during an investigation, short enough to bound storage cost.
# Bumping `expiration.days` is the only change needed if a compliance
# regime ever demands longer.
resource "aws_s3_bucket_lifecycle_configuration" "nlb_access_logs" {
  bucket = aws_s3_bucket.nlb_access_logs.id
  rule {
    id     = "expire-old"
    status = "Enabled"
    filter {}
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

# Bucket policy required by NLB access-log delivery, which writes via
# the log-delivery service (delivery.logs.amazonaws.com) - unlike ALB,
# which writes from a per-region ELB account. Shape comes from the AWS
# docs ("Enable access logs for your Network Load Balancer"); the
# SourceAccount/SourceArn conditions are the documented
# confused-deputy guard.
data "aws_iam_policy_document" "nlb_access_logs" {
  statement {
    sid     = "AWSLogDeliveryAclCheck"
    actions = ["s3:GetBucketAcl"]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    resources = [aws_s3_bucket.nlb_access_logs.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  statement {
    sid     = "AWSLogDeliveryWrite"
    actions = ["s3:PutObject"]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    resources = ["${aws_s3_bucket.nlb_access_logs.arn}/mail-nlb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_s3_bucket_policy" "nlb_access_logs" {
  bucket = aws_s3_bucket.nlb_access_logs.id
  policy = data.aws_iam_policy_document.nlb_access_logs.json
}
