output "bucket_arn" {
  value = aws_s3_bucket.react_app.arn
}

output "bucket" {
  value = aws_s3_bucket.bucket
}