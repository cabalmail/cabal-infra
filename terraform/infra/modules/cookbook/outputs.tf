output "bucket" {
  value       = aws_s3_bucket.cookbook
  description = "S3 bucket for storing cookbook archive."
}

output "etag" {
  value       = aws_s3_bucket_object.cookbook.etag
  description = "Hash that changes when the cookbook changes"
}