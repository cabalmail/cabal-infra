resource "aws_cloudfront_origin_access_identity" "cabal_s3_origin" {
  comment = "Static admin website"
}

resource "aws_cloudfront_distribution" "cabal_cdn" {
  origin {
    domain_name = aws_s3_bucket.cabal_website_bucket.bucket_regional_domain_name
    origin_id   = "cabal_admin_s3"

    s3_origin_config {
      origin_access_identity = "origin-access-identity/cloudfront/${aws_cloudfront_origin_access_identity.cabal_s3_origin.id}"
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

    viewer_protocol_policy = "allow-all"
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
  }
}

resource "aws_route53_record" "cabal_admin_cname" {
  zone_id = var.zone_id
  name    = "admin.${var.control_domain}"
  type    = "CNAME"
  ttl     = "300"
  records = [aws_cloudfront_distribution.cabal_cdn.domain_name]
}