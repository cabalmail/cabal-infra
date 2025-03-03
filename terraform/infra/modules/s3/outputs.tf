output "bucket_arn" {
  value = local.bucket_arn
}

output "bucket" {
  value = aws_s3_bucket.this.id
}

output "domain_name" {
  value = aws_s3_bucket.this.bucket_domain_name
}

output "origin" {
  value = aws_cloudfront_origin_access_identity.origin.id
}
