# Runtime configuration for React app
resource "aws_s3_object" "website_config" {
  bucket       = var.bucket
  key          = "/config.js"
  content_type = "text/javascript"
  content      = templatefile("${path.module}/templates/config.js", {
    pool_id        = var.user_pool_id,
    pool_client_id = var.user_pool_client_id,
    region         = var.region,
    invoke_url     = "${aws_api_gateway_deployment.deployment.invoke_url}${aws_api_gateway_stage.api_stage.stage_name}",
    domains        = var.domains,
    control_domain = var.control_domain
  })
  etag         = md5(templatefile("${path.module}/templates/config.js", {
      pool_id        = var.user_pool_id,
      pool_client_id = var.user_pool_client_id,
      region         = var.region,
      invoke_url     = "${aws_api_gateway_deployment.deployment.invoke_url}${aws_api_gateway_stage.api_stage.stage_name}",
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
  content      = join("", [
      "exports.config = ",
      templatefile("${path.module}/templates/config.js",
      ";"
    ], {
    pool_id        = var.user_pool_id,
    pool_client_id = var.user_pool_client_id,
    region         = var.region,
    invoke_url     = "${aws_api_gateway_deployment.deployment.invoke_url}${aws_api_gateway_stage.api_stage.stage_name}",
    domains        = var.domains,
    control_domain = var.control_domain
  })
  etag         = md5(templatefile("${path.module}/templates/config.js", {
      pool_id        = var.user_pool_id,
      pool_client_id = var.user_pool_client_id,
      region         = var.region,
      invoke_url     = "${aws_api_gateway_deployment.deployment.invoke_url}${aws_api_gateway_stage.api_stage.stage_name}",
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
    id = "expire_attachments"
    expiration {
      days = 2
    }
    status = "Enabled"
  }
}

# Make the bucket private
resource "aws_s3_bucket_acl" "this" {
  bucket = aws_s3_bucket.cache.bucket
  acl    = "private"
}

# Make the bucvket stay private
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.cache.bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}