# Runtime configuration for React app.
#
# cache_control = "no-cache" makes browsers and CloudFront revalidate every
# request against the origin (ETag match returns 304 with no body), so a
# Terraform-only change to Cognito/API values reaches clients on next page
# load without a CloudFront invalidation. CloudFront honors the origin's
# Cache-Control over its default_ttl.
resource "aws_s3_object" "website_config" {
  bucket        = var.bucket
  key           = "/config.js"
  content_type  = "text/javascript"
  cache_control = "no-cache"
  content = templatefile("${path.module}/templates/config.js", {
    pool_id             = var.user_pool_id,
    pool_client_id      = var.user_pool_client_id,
    region              = var.region,
    invoke_url          = "https://${aws_api_gateway_rest_api.gateway.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}",
    domains             = var.domains,
    control_domain      = var.control_domain,
    invitation_required = var.invitation_required,
    monitoring          = var.monitoring
  })
  etag = md5(templatefile("${path.module}/templates/config.js", {
    pool_id             = var.user_pool_id,
    pool_client_id      = var.user_pool_client_id,
    region              = var.region,
    invoke_url          = "https://${aws_api_gateway_rest_api.gateway.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}",
    domains             = var.domains,
    control_domain      = var.control_domain,
    invitation_required = var.invitation_required,
    monitoring          = var.monitoring
    })
  )
}

# Runtime configuration for the Apple client.
#
# The Apple client cannot execute `config.js`, so we emit a sibling JSON
# object with the same shape. The underlying template already produces
# valid JSON, so it is reused verbatim. See docs/0.6.0/ios-client-plan.md.
resource "aws_s3_object" "website_config_json" {
  bucket        = var.bucket
  key           = "/config.json"
  content_type  = "application/json"
  cache_control = "no-cache"
  content = templatefile("${path.module}/templates/config.js", {
    pool_id             = var.user_pool_id,
    pool_client_id      = var.user_pool_client_id,
    region              = var.region,
    invoke_url          = "https://${aws_api_gateway_rest_api.gateway.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}",
    domains             = var.domains,
    control_domain      = var.control_domain,
    invitation_required = var.invitation_required,
    monitoring          = var.monitoring
  })
  etag = md5(templatefile("${path.module}/templates/config.js", {
    pool_id             = var.user_pool_id,
    pool_client_id      = var.user_pool_client_id,
    region              = var.region,
    invoke_url          = "https://${aws_api_gateway_rest_api.gateway.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}",
    domains             = var.domains,
    control_domain      = var.control_domain,
    invitation_required = var.invitation_required,
    monitoring          = var.monitoring
    })
  )
}

# Runtime configuration for Node Lambdas
resource "aws_s3_object" "node_config" {
  bucket       = var.bucket
  key          = "/node_config.js"
  content_type = "text/javascript"
  content = templatefile("${path.module}/templates/node_config.js", {
    invoke_url     = "https://${aws_api_gateway_rest_api.gateway.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}",
    domains        = var.domains,
    control_domain = var.control_domain
  })
  etag = md5(templatefile("${path.module}/templates/node_config.js", {
    invoke_url     = "https://${aws_api_gateway_rest_api.gateway.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}",
    domains        = var.domains,
    control_domain = var.control_domain
    })
  )
}

# Bucket for app cache.
#
# Versioning is intentionally off: every object here is a regenerable
# derivative (cached .eml bodies, attachment staging, DMARC reports,
# config.js) and the lifecycle rule below expires all of them after two
# days, so retaining noncurrent versions would add cost with nothing to
# recover. CKV_AWS_21 / AWS-0090 are suppressed for this bucket alone -
# the durable buckets (modules/s3, modules/front_door) do version.
resource "aws_s3_bucket" "cache" {
  #checkov:skip=CKV_AWS_21:Transient cache - all objects expire after two days (lifecycle rule below); versioning would only retain regenerable derivatives.
  bucket = "cache.${var.control_domain}"
}

# Expire objects after two days
resource "aws_s3_bucket_lifecycle_configuration" "expire_attachments" {
  bucket = aws_s3_bucket.cache.bucket
  rule {
    id = "expire_attachments"
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

# Server access logs -> shared target bucket (modules/s3_access_logs), the
# CKV_AWS_18 / AWS-0089 audit trail. This is the one content bucket reached
# directly by clients (CORS presigned GET/PUT) and Lambdas, so its access
# records have the most audit value despite the two-day object expiry.
resource "aws_s3_bucket_logging" "cache" {
  bucket        = aws_s3_bucket.cache.bucket
  target_bucket = var.access_logs_bucket
  target_prefix = "cache/"
}

# Allow the admin web client to XHR-fetch cached .eml bodies for the reader's
# View-source modal (GET) and to PUT outbound-attachment bodies directly to
# the staging prefix (issue #377). Apple clients bypass CORS entirely.
resource "aws_s3_bucket_cors_configuration" "cache" {
  bucket = aws_s3_bucket.cache.bucket

  cors_rule {
    allowed_methods = ["GET", "PUT"]
    allowed_origins = ["https://admin.${var.control_domain}"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}
