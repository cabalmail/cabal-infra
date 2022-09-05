resource "aws_cloudfront_origin_access_identity" "origin" {
  comment = "Static admin website"
}

#tfsec:ignore:aws-cloudfront-enable-logging
#tfsec:ignore:aws-cloudfront-enable-waf
resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name = jsondecode(data.aws_ssm_parameter.s3.value).bucket_regional_domain_name
    origin_id   = "cabal_admin_s3"

    s3_origin_config {
      origin_access_identity = "origin-access-identity/cloudfront/${aws_cloudfront_origin_access_identity.origin.id}"
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

resource "aws_s3_bucket_policy" "react_app_policy" {
  bucket = jsondecode(data.aws_ssm_parameter.s3.value).id
  policy = <<EOP
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Caesar",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity ${aws_cloudfront_origin_access_identity.origin.id}"
            },
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::admin.cabal-mail.net/*"
        },
        {
            "Sid": "AndNancy",
            "Effect": "Deny",
            "Principal": {
                "AWS": "arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity ${aws_cloudfront_origin_access_identity.origin.id}"
            },
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::admin.cabal-mail.net/cabal.tar.gz"
        }
    ]
}
EOP
}

resource "aws_route53_record" "admin_cname" {
  zone_id = var.zone_id
  name    = "admin.${var.control_domain}"
  type    = "CNAME"
  ttl     = "300"
  records = [aws_cloudfront_distribution.cdn.domain_name]
}