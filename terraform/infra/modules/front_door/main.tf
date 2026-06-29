/**
* Creates an S3-backed CloudFront site published at www.<control_domain>.
*
* Purpose: a public-facing front door surface separate from the React
* admin app at admin.<control_domain>. The privacy policy and terms of
* service live here so they can be referenced as public URLs by carrier
* registrations (AWS End User Messaging toll-free verification)
* without auth-gating the admin app.
*
* This module owns the S3 bucket, the CloudFront distribution, the
* Route 53 records, and the SSM parameter that publishes the
* distribution ID. It does NOT upload site content - that ships out of
* band via .github/workflows/app.yml (front_door area), which renders
* {{VAR}} placeholders in front-door/ from env vars and `aws s3 sync`s
* the result into the bucket, then invalidates the distribution. The
* workflow looks up the distribution ID by reading the SSM parameter
* created here.
*/

locals {
  bucket_name = "www.${var.control_domain}"
  site_host   = "www.${var.control_domain}"
}

resource "aws_s3_bucket" "this" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_website_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  index_document {
    suffix = "index.html"
  }
  error_document {
    key = "404.html"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning lets an accidentally overwritten or deleted published
# object (the privacy policy / terms of service referenced by carrier
# registration) be recovered. The site is small and rarely changes, so
# noncurrent versions are negligible.
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Server access logs -> shared target bucket (modules/s3_access_logs), the
# CKV_AWS_18 / AWS-0089 audit trail. This bucket is served via CloudFront
# OAC, so the records capture origin fetches and deploy-time content syncs.
resource "aws_s3_bucket_logging" "this" {
  bucket        = aws_s3_bucket.this.id
  target_bucket = var.access_logs_bucket
  target_prefix = "front-door/"
}

# LEGACY origin access identity, superseded by the OAC below (Phase 5
# of docs/0.10.x/resilience-continuity-hardening-plan.md). Kept,
# together with its bucket-policy statement, so the distribution keeps
# serving while the OAC config propagates and as the rollback path.
# Removal order, once the OAC cutover is verified in every
# environment: delete this resource and the OAI statement in the
# policy document below in one apply - nothing else references them.
resource "aws_cloudfront_origin_access_identity" "this" {
  comment = "Cabalmail front door site (${local.site_host})"
}

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "cabal-front-door-oac"
  description                       = "OAC for the front door bucket (${local.site_host})"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "bucket" {
  # Legacy OAI grant - delete together with the OAI resource above
  # once the OAC cutover is verified.
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.this.iam_arn]
    }
  }

  # OAC grant: CloudFront signs origin requests as the service
  # principal, scoped to exactly our distribution by SourceArn.
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json
}

#tfsec:ignore:aws-cloudfront-enable-logging
#tfsec:ignore:aws-cloudfront-enable-waf
resource "aws_cloudfront_distribution" "this" {
  origin {
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id                = "front_door_s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Cabalmail front door site"
  default_root_object = "index.html"
  aliases             = [local.site_host]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "front_door_s3"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 600
    max_ttl                = 86400
    viewer_protocol_policy = "redirect-to-https"
  }

  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = false
    acm_certificate_arn            = var.cert_arn
    ssl_support_method             = "sni-only"
    # Newest TLS 1.2 policy AWS publishes (the plan named TLSv1.2_2023,
    # which does not exist). Still permits TLS 1.2 clients; a TLSv1.3
    # floor is a separate decision.
    minimum_protocol_version = "TLSv1.2_2025"
  }
}

resource "aws_route53_record" "this" {
  zone_id = var.zone_id
  name    = local.site_host
  type    = "CNAME"
  ttl     = "300"
  records = [aws_cloudfront_distribution.this.domain_name]
}

# Mirror into the private zone so VPC-internal callers can resolve
# www.<control_domain>. Matches the pattern used by the admin CNAME
# in modules/app/cloudfront.tf.
resource "aws_route53_record" "this_private" {
  zone_id = var.private_zone_id
  name    = local.site_host
  type    = "CNAME"
  ttl     = "300"
  records = [aws_cloudfront_distribution.this.domain_name]
}

# Release the previously-managed front door content from Terraform
# state without deleting the live objects out of the bucket. The
# initial drop of this module (under its earlier name, marketing_site)
# managed every file under marketing-site/ as
# aws_s3_object.site["..."]. Ownership has moved to
# .github/workflows/app.yml (front_door area); this block lets the
# next terraform apply drop those state entries cleanly. Safe to
# delete once every environment has applied past this change.
removed {
  from = aws_s3_object.site
  lifecycle {
    destroy = false
  }
}

# Published so .github/workflows/app.yml can invalidate the distribution
# after `aws s3 sync` without taking a Terraform dependency. Mirrors
# the /cabal/react-config/cf-distribution parameter the React deploy
# job reads.
resource "aws_ssm_parameter" "cf_distribution" {
  name        = "/cabal/front-door/cf-distribution"
  description = "CloudFront Distribution ID for front door site deploy invalidation"
  type        = "String"
  value       = aws_cloudfront_distribution.this.id
}
