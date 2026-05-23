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

resource "aws_cloudfront_origin_access_identity" "this" {
  comment = "Cabalmail front door site (${local.site_host})"
}

data "aws_iam_policy_document" "bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.this.iam_arn]
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
    domain_name = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id   = "front_door_s3"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.this.cloudfront_access_identity_path
    }
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
    minimum_protocol_version       = "TLSv1.2_2021"
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
