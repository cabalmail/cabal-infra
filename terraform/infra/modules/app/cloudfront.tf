# Origin access control (OAC), successor to the legacy origin access
# identity (OAI). The bucket policy below trusts the
# cloudfront.amazonaws.com service principal scoped to this
# distribution's ARN instead of the OAI canonical user. The OAI
# resource in modules/s3 stays (with its grant below) until the OAC
# cutover is verified; see the removal-order comment there.
resource "aws_cloudfront_origin_access_control" "admin" {
  name                              = "cabal-admin-oac"
  description                       = "OAC for the admin app bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# The admin bucket's policy lives here, next to the distribution,
# because the OAC grant needs the distribution ARN: housing it in the
# s3 module would make the two modules reference each other, which
# Terraform resolves fine (acyclic at the resource level) but
# checkov's graph renderer does not.
data "aws_iam_policy_document" "admin_bucket" {
  # Legacy OAI grant - delete together with the OAI resource and
  # oai_iam_arn output in modules/s3 once the OAC cutover is verified.
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [var.oai_iam_arn]
    }
  }

  # OAC grant: CloudFront signs origin requests as the service
  # principal, scoped to exactly our distribution by SourceArn.
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "admin_bucket" {
  bucket = var.bucket
  policy = data.aws_iam_policy_document.admin_bucket.json
}

#tfsec:ignore:aws-cloudfront-enable-logging
#tfsec:ignore:aws-cloudfront-enable-waf
resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name              = var.bucket_domain_name
    origin_id                = "cabal_admin_s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.admin.id
  }
  origin {
    domain_name = split("/", aws_api_gateway_stage.api_stage.invoke_url)[2]
    origin_id   = "cabal_api"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Cabal admin website"
  default_root_object = "index.html"
  aliases             = ["admin.${var.control_domain}"]
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "cabal_admin_s3"
    forwarded_values {
      query_string = true
      cookies {
        forward = "none"
      }
    }
    min_ttl                = 0
    default_ttl            = var.dev_mode ? 0 : 600
    max_ttl                = var.dev_mode ? 0 : 86400
    viewer_protocol_policy = "redirect-to-https"
  }
  ordered_cache_behavior {
    path_pattern     = "/${var.stage_name}/*"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "cabal_api"

    forwarded_values {
      query_string = true
      headers      = ["Authorization"]
      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
    compress               = true
    viewer_protocol_policy = "https-only"
  }

  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US"]
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

resource "aws_route53_record" "admin_cname" {
  zone_id = var.zone_id
  name    = "admin.${var.control_domain}"
  type    = "CNAME"
  ttl     = "300"
  records = [aws_cloudfront_distribution.cdn.domain_name]
}

# The VPC private zone shadows the public zone for the control domain;
# without a sibling record, VPC-internal callers (e.g. Kuma probes) can't
# resolve admin.<control-domain>. CloudFront's public DNS name resolves
# globally, so the CNAME target works from inside the VPC.
resource "aws_route53_record" "admin_cname_private" {
  zone_id = var.private_zone_id
  name    = "admin.${var.control_domain}"
  type    = "CNAME"
  ttl     = "300"
  records = [aws_cloudfront_distribution.cdn.domain_name]
}

resource "aws_ssm_parameter" "cf_distribution" {
  name        = "/cabal/react-config/cf-distribution"
  description = "CloudFront Distribution ID for React deployment invalidation"
  type        = "String"
  value       = aws_cloudfront_distribution.cdn.id
}
