locals {
  bucket     = "admin.${var.control_domain}"
  bucket_arn = "arn:aws:s3:::admin.${var.control_domain}"
}

resource "aws_s3_bucket" "this" {
  bucket = local.bucket
}

resource "aws_s3_bucket_website_configuration" "react_app_website" {
  bucket = local.bucket
  index_document {
    suffix = "index.html"
  }
  error_document {
    key = "error.html"
  }
}

# LEGACY origin access identity, superseded by the OAC in
# modules/app/cloudfront.tf (Phase 5 of
# docs/0.10.x/resilience-continuity-hardening-plan.md). Kept, together
# with its grant in the app module's bucket policy, so the
# distribution keeps serving while the OAC config propagates and as
# the rollback path. Removal order, once the OAC cutover is verified
# in every environment: delete this resource, the oai_iam_arn output,
# and the OAI statement in the app module's policy document in one
# apply.
#
# The bucket POLICY lives in modules/app (next to the distribution),
# not here: it needs the distribution ARN for its OAC SourceArn
# condition, and while Terraform is happy with the mutual
# bucket-module/app-module reference that would otherwise create (it
# is acyclic at the resource level), checkov's graph renderer is not -
# it stops resolving unrelated variables and reports phantom findings
# on count-gated resources elsewhere in the stack.
resource "aws_cloudfront_origin_access_identity" "origin" {
  comment = "Static admin website"
}

resource "aws_s3_bucket_public_access_block" "react_access" {
  bucket = local.bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
