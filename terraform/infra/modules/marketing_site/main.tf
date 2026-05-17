/**
* Creates an S3-backed CloudFront site published at www.<control_domain>.
*
* Purpose: a public-facing marketing surface separate from the React
* admin app at admin.<control_domain>. The privacy policy and terms of
* service live here so they can be referenced as public URLs by carrier
* registrations (AWS End User Messaging toll-free verification, Twilio
* A2P 10DLC) without auth-gating the admin app.
*
* Content is uploaded from the marketing-site/ directory at the repo
* root via aws_s3_object. Placeholder content is committed alongside
* this module; real marketing copy and design land in a later
* milestone. When that lands, the simplest migration is to swap the
* aws_s3_object resources for an `aws s3 sync` step in app.yml driven
* by a path filter on marketing-site/**.
*/

locals {
  bucket_name = "www.${var.control_domain}"
  site_host   = "www.${var.control_domain}"

  # Files to upload, with their content-type. fileset() is recursive,
  # so subdirectories under marketing-site/ are picked up automatically
  # when added later. The map keeps content-type assignment explicit
  # rather than guessing from the extension.
  content_types = {
    "html" = "text/html; charset=utf-8"
    "css"  = "text/css; charset=utf-8"
    "js"   = "application/javascript; charset=utf-8"
    "json" = "application/json; charset=utf-8"
    "svg"  = "image/svg+xml"
    "png"  = "image/png"
    "jpg"  = "image/jpeg"
    "jpeg" = "image/jpeg"
    "ico"  = "image/x-icon"
    "txt"  = "text/plain; charset=utf-8"
    "xml"  = "application/xml; charset=utf-8"
  }

  site_files = fileset(var.site_root, "**/*")
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
  comment = "Cabalmail marketing site (${local.site_host})"
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

# Upload every file under marketing-site/ as an object in the bucket.
# content_type is resolved from the file extension; unknown extensions
# fall back to application/octet-stream which is safe but unhelpful in
# a browser - keep the content_types map above current as the site
# grows. etag = filemd5() forces Terraform to upload a new object
# whenever the file content changes locally.
#
# tfsec:ignore:aws-s3-encryption-customer-key:default S3 SSE-S3
# applies; no need for a customer-managed KMS key for a public site.
resource "aws_s3_object" "site" {
  for_each     = local.site_files
  bucket       = aws_s3_bucket.this.id
  key          = each.value
  source       = "${var.site_root}/${each.value}"
  etag         = filemd5("${var.site_root}/${each.value}")
  content_type = lookup(local.content_types, lower(reverse(split(".", each.value))[0]), "application/octet-stream")
}

#tfsec:ignore:aws-cloudfront-enable-logging
#tfsec:ignore:aws-cloudfront-enable-waf
resource "aws_cloudfront_distribution" "this" {
  origin {
    domain_name = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id   = "marketing_site_s3"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.this.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Cabalmail marketing site"
  default_root_object = "index.html"
  aliases             = [local.site_host]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "marketing_site_s3"

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
