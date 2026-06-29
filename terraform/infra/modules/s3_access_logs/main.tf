/**
* Shared S3 server-access-log target for the stack's content buckets.
*
* CKV_AWS_18 / AWS-0089 want a server-access-log audit trail on each
* content bucket. S3 server access logging delivers to a separate target
* bucket in the same account and region; this module owns that single
* shared target. The three content buckets attach an
* aws_s3_bucket_logging that writes here under a distinct prefix:
*   admin.<control_domain> (modules/s3)        -> admin/
*   www.<control_domain>   (modules/front_door) -> front-door/
*   cache.<control_domain> (modules/app)        -> cache/
*
* Delivery is authorized by a bucket policy granting the S3 logging
* service principal (logging.s3.amazonaws.com) PutObject, scoped by
* aws:SourceAccount and to exactly the three source bucket ARNs - the
* documented confused-deputy guard. The legacy log-delivery-group ACL
* mechanism is deliberately not used: buckets here are created with
* Object Ownership BucketOwnerEnforced (ACLs disabled, the modern S3
* default), so the policy grant is the only path that works.
*/

data "aws_caller_identity" "current" {}

locals {
  # Source bucket names are deterministic from the control domain, so the
  # delivery policy scopes to them without a cross-module reference.
  source_bucket_arns = [
    "arn:aws:s3:::admin.${var.control_domain}", # modules/s3: React bundle + Lambda deploy zips
    "arn:aws:s3:::www.${var.control_domain}",   # modules/front_door: public privacy/ToS site
    "arn:aws:s3:::cache.${var.control_domain}", # modules/app: transient message/attachment cache
  ]
}

# Logging this bucket into itself would recurse, and a second bucket for
# meta-logs is not worth it for operational access records; replication is
# likewise skipped because the logs expire in 180 days and exist for
# incident response, not durability.
#trivy:ignore:AVD-AWS-0089 # access-logging the access-log bucket recurses; meta-logs not worth a second bucket
resource "aws_s3_bucket" "access_logs" {
  #checkov:skip=CKV_AWS_18:access-logging the access-log bucket recurses; meta-logs not worth a second bucket
  #checkov:skip=CKV_AWS_144:operational access logs with a 180-day expiry; cross-region replication buys nothing
  #checkov:skip=CKV2_AWS_62:no consumer for object-created events on a log bucket
  bucket = "cabal-s3-access-logs-${data.aws_caller_identity.current.account_id}"
}

# Versioning protects delivered log objects from silent overwrite or
# deletion; the lifecycle below clears noncurrent versions after 30 days.
resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3, not SSE-KMS: S3 log delivery does not support a customer-managed
# key, and the repo's posture (see BASELINE.md, CMK class) deliberately
# avoids one. AES256 satisfies encryption-at-rest.
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 180-day retention bounds storage cost (matching the NLB access-log
# bucket); noncurrent versions clear after 30 days and incomplete
# multipart uploads after 7.
resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
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

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 server access log delivery writes as the logging service principal
# (logging.s3.amazonaws.com). Shape and confused-deputy conditions come
# from the AWS docs ("Enabling Amazon S3 server access logging" - grant
# delivery using a bucket policy).
data "aws_iam_policy_document" "access_logs" {
  statement {
    sid     = "S3ServerAccessLogsPolicy"
    actions = ["s3:PutObject"]
    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }
    resources = ["${aws_s3_bucket.access_logs.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = local.source_bucket_arns
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = data.aws_iam_policy_document.access_logs.json
}
