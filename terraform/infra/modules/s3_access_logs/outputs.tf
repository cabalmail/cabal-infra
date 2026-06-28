# Target bucket name for the content buckets' aws_s3_bucket_logging
# target_bucket. depends_on the delivery policy so consumers order their
# logging config after delivery is authorized - S3 validates the target
# bucket grants the logging service write access at apply time.
output "bucket" {
  description = "Name of the shared S3 server-access-log target bucket."
  value       = aws_s3_bucket.access_logs.id
  depends_on  = [aws_s3_bucket_policy.access_logs]
}
