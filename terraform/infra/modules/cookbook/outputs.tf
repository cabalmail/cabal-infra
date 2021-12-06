output "bucket" {
  value       = aws_s3_bucket.cookbook
  description = "S3 bucket for storing cookbook archive."
}