# S3 bucket for deploying React app
resource "aws_s3_bucket" "react_app" {
  bucket = "admin.${var.control_domain}"
}

resource "aws_s3_bucket_lifecycle_configuration" "expire_attachments" {
  bucket = aws_s3_bucket.react_app.bucket
  rule {
    id = "expire_attachments"
    expiration {
      days = 2
    }
    filter {
      prefix = "attachment/"
    }
    status = "Enabled"
  }
}

resource "aws_s3_bucket_website_configuration" "react_app_website" {
  bucket = aws_s3_bucket.react_app.id
  index_document {
    suffix = "index.html"
  }
  error_document {
    key = "error.html"
  }
}

resource "aws_s3_bucket_acl" "react_app_acl" {
  bucket = aws_s3_bucket.react_app.id
  acl    = "private"
}

resource "aws_cloudfront_origin_access_identity" "origin" {
  comment = "Static admin website"
}

data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.react_app.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.origin.iam_arn]
    }
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.react_app.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["message-cache/\${cognito-identity.amazonaws.com:sub}/*"]
      }
    }
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${aws_s3_bucket.react_app.id}/message-cache/\${cognito-identity.amazonaws.com:sub}/*"
    ]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["message-cache/\${cognito-identity.amazonaws.com:sub}/*"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "react_policy" {
  bucket = aws_s3_bucket.react_app.id
  policy = data.aws_iam_policy_document.s3_policy.json
}

resource "aws_s3_bucket_public_access_block" "react_access" {
  bucket = aws_s3_bucket.react_app.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Save bucket information in AWS SSM Parameter Store so that terraform/infra can read it.
resource "aws_ssm_parameter" "react_app" {
  name        = "/cabal/admin/bucket"
  description = "S3 bucket for React App"
  type        = "String"
  value       = jsonencode(aws_s3_bucket.react_app)
}
resource "aws_ssm_parameter" "bucket_name" {
  name        = "/cabal/react-config/s3-bucket"
  description = "S3 bucket for React App deployment"
  type        = "String"
  value       = aws_s3_bucket.react_app.id
}
resource "aws_ssm_parameter" "origin_id" {
  name        = "/cabal/react-config/origin-id"
  description = "S3 bucket for React App deployment"
  type        = "String"
  value       = aws_cloudfront_origin_access_identity.origin.id
}
