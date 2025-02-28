#tfsec:ignore:aws-cloudfront-enable-logging
#tfsec:ignore:aws-cloudfront-enable-waf
resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name = var.bucket_domain_name
    origin_id   = "cabal_admin_s3"

    s3_origin_config {
      origin_access_identity = "origin-access-identity/cloudfront/${var.origin}"
    }
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
    minimum_protocol_version       = "TLSv1.2_2021"
  }
}

resource "aws_route53_record" "admin_cname" {
  zone_id = var.zone_id
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
