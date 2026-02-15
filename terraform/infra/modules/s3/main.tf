locals {
  bucket     = "admin.${var.control_domain}"
  bucket_arn = "arn:aws:s3:::admin.${var.control_domain}"
}

resource "aws_s3_bucket" "this" {
  bucket = local.bucket
}

resource "aws_s3_bucket_website_configuration" "react_app_website" {
  bucket = local.bucket
  index_document {
    suffix = "index.html"
  }
  error_document {
    key = "error.html"
  }
}

resource "aws_cloudfront_origin_access_identity" "origin" {
  comment = "Static admin website"
}

data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.origin.iam_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "react_policy" {
  bucket = local.bucket
  policy = data.aws_iam_policy_document.s3_policy.json
}

resource "aws_s3_bucket_public_access_block" "react_access" {
  bucket = local.bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
