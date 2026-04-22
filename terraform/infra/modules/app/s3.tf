# Runtime configuration for React app
resource "aws_s3_object" "website_config" {
  bucket       = var.bucket
  key          = "/config.js"
  content_type = "text/javascript"
  content      = templatefile("${path.module}/templates/config.js", {
    pool_id        = var.user_pool_id,
    pool_client_id = var.user_pool_client_id,
    region         = var.region,
    invoke_url     = "https://${aws_api_gateway_rest_api.gateway.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}",
    domains        = var.domains,
    control_domain = var.control_domain
  })
  etag         = md5(templatefile("${path.module}/templates/config.js", {
      pool_id        = var.user_pool_id,
      pool_client_id = var.user_pool_client_id,
      region         = var.region,
      invoke_url     = "https://${aws_api_gateway_rest_api.gateway.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}",
      domains        = var.domains,
      control_domain = var.control_domain
    })
  )
}

# Runtime configuration for the Apple client.
#
# The Apple client cannot execute `config.js`, so we emit a sibling JSON
# object with the same shape. The underlying template already produces
# valid JSON, so it is reused verbatim. See docs/0.6.0/ios-client-plan.md.
resource "aws_s3_object" "website_config_json" {
  bucket       = var.bucket
  key          = "/config.json"
  content_type = "application/json"
  content      = templatefile("${path.module}/templates/config.js", {
    pool_id        = var.user_pool_id,
    pool_client_id = var.user_pool_client_id,
    region         = var.region,
    invoke_url     = "https://${aws_api_gateway_rest_api.gateway.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}",
    domains        = var.domains,
    control_domain = var.control_domain
  })
  etag         = md5(templatefile("${path.module}/templates/config.js", {
      pool_id        = var.user_pool_id,
      pool_client_id = var.user_pool_client_id,
      region         = var.region,
      invoke_url     = "https://${aws_api_gateway_rest_api.gateway.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}",
      domains        = var.domains,
      control_domain = var.control_domain
    })
  )
}

# Runtime configuration for Node Lambdas
resource "aws_s3_object" "node_config" {
  bucket       = var.bucket
  key          = "/node_config.js"
  content_type = "text/javascript"
  content      = templatefile("${path.module}/templates/node_config.js", {
    invoke_url     = "https://${aws_api_gateway_rest_api.gateway.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}",
    domains        = var.domains,
    control_domain = var.control_domain
  })
  etag         = md5(templatefile("${path.module}/templates/node_config.js", {
      invoke_url     = "https://${aws_api_gateway_rest_api.gateway.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}",
      domains        = var.domains,
      control_domain = var.control_domain
    })
  )
}

# Bucket for app cache
resource "aws_s3_bucket" "cache" {
  bucket = "cache.${var.control_domain}"
}

# Expire objects after two days
resource "aws_s3_bucket_lifecycle_configuration" "expire_attachments" {
  bucket = aws_s3_bucket.cache.bucket
  rule {
    id     = "expire_attachments"
    filter {
      prefix = "/"
    }
    expiration {
      days = 2
    }
    status = "Enabled"
  }
}

# Make the bucvket stay private
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.cache.bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Allow the admin web client to XHR-fetch cached .eml bodies for the reader's
# View-source modal. Attachments and inline images don't need this (they are
# loaded via top-level navigation or <img>, neither of which is CORS-gated),
# but axios.get(signedUrl) in ViewSourceModal is an XHR that the browser
# blocks without an Access-Control-Allow-Origin response header.
resource "aws_s3_bucket_cors_configuration" "cache" {
  bucket = aws_s3_bucket.cache.bucket

  cors_rule {
    allowed_methods = ["GET"]
    allowed_origins = ["https://admin.${var.control_domain}"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}
