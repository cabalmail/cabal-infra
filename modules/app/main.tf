# TODO:
# CloudFront for static website

data "aws_caller_identity" "current" {}

resource "aws_api_gateway_rest_api" "cabal_gateway" {
  name = "cabal_gateway"
}

resource "aws_api_gateway_authorizer" "cabal_api_authorizer" {
  name                   = "cabal_pool"
  rest_api_id            = aws_api_gateway_rest_api.cabal_gateway.id
  type                   = "COGNITO_USER_POOLS"
  provider_arns          = [ join("",[
    "arn:aws:cognito-idp:",
    var.region,
    ":",
    data.aws_caller_identity.current.account_id,
    ":userpool/",
    var.user_pool_id
  ]) ]
}

module "cabal_list_method" {
  source           = "./modules/call"
  name             = "list"
  runtime          = "nodejs14.x"
  method           = "GET"
  region           = var.region
  account          = data.aws_caller_identity.current.account_id
  gateway_id       = aws_api_gateway_rest_api.cabal_gateway.id
  root_resource_id = aws_api_gateway_rest_api.cabal_gateway.root_resource_id
  authorizer       = aws_api_gateway_authorizer.cabal_api_authorizer.id
}

module "cabal_request_method" {
  source           = "./modules/call"
  name             = "request"
  runtime          = "nodejs14.x"
  method           = "POST"
  region           = var.region
  account          = data.aws_caller_identity.current.account_id
  gateway_id       = aws_api_gateway_rest_api.cabal_gateway.id
  root_resource_id = aws_api_gateway_rest_api.cabal_gateway.root_resource_id
  authorizer       = aws_api_gateway_authorizer.cabal_api_authorizer.id
}

module "cabal_revoke_method" {
  source           = "./modules/call"
  name             = "revoke"
  runtime          = "nodejs14.x"
  method           = "DELETE"
  region           = var.region
  account          = data.aws_caller_identity.current.account_id
  gateway_id       = aws_api_gateway_rest_api.cabal_gateway.id
  root_resource_id = aws_api_gateway_rest_api.cabal_gateway.root_resource_id
  authorizer       = aws_api_gateway_authorizer.cabal_api_authorizer.id
}

resource "aws_cloudfront_distribution" "cabal_cdn" {
  origin {
    domain_name = aws_s3_bucket.cabal_website_bucket.bucket_regional_domain_name
    origin_id   = "cabal_admin_s3"

    s3_origin_config {
      origin_access_identity = "origin-access-identity/cloudfront/ABCDEFG1234567"
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
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
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
    acm_certificate_arn            = var.cert
  }
}

resource "aws_s3_bucket" "cabal_website_bucket" {
  # acl    = "public-read"
  acl    = "private"
  bucket = "admin.${var.control_domain}"
  # website {
  #   index_document = "index.html"
  #   error_document = "error.html"
  # }
  # cors_rule {
  #   allowed_headers = ["*"]
  #   allowed_methods = ["PUT", "POST"]
  #   allowed_origins = ["https://admin.${var.control_domain}"]
  #   expose_headers  = ["ETag"]
  #   max_age_seconds = 3000
  # }
}

resource "aws_s3_bucket_policy" "cabal_website_bucket_policy" {
  bucket = aws_s3_bucket.cabal_website_bucket.id
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
        {
          "Sid": "Viscious",
          "Effect": "Allow",
          "Principal": {
            "AWS": "arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity ${aws_cloudfront_distribution.cabal_cdn.id}"
          },
          "Action": "s3:GetObject",
          "Resource": "arn:aws:s3:::admin.${var.control_domain}/*"
        }
    ]
  })
}

resource "aws_s3_bucket_object" "cabal_website_files" {
  for_each = fileset(path.module, "objects/**/*")

  bucket   = aws_s3_bucket.cabal_website_bucket.bucket
  key      = each.value
  source   = "${path.module}/${each.value}"
  etag     = filemd5("${path.module}/${each.value}")
}

resource "aws_s3_bucket_object" "cabal_website_templates" {
  for_each = fileset(path.module, "templates/**/*")

  bucket   = aws_s3_bucket.cabal_website_bucket.bucket
  key      = each.value
  content  = templatefile("${path.module}/${each.value}", {
    pool_id        = var.user_pool_id,
    pool_client_id = var.user_pool_client_id,
    region         = var.region,
    invoke_url     = "http://example.com/"
  })
  etag     = md5(templatefile("${path.module}/${each.value}", {
      pool_id        = var.user_pool_id,
      pool_client_id = var.user_pool_client_id,
      region         = var.region,
      invoke_url     = "http://example.com/"
    })
  )
}
