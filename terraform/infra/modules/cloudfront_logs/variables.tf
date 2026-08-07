variable "distributions" {
  type        = map(string)
  description = "CloudFront distributions to deliver access logs for, keyed by a short stable name used in both the delivery-source name and the S3 key prefix. Values are distribution ARNs."
}

variable "destination_bucket_arn" {
  type        = string
  description = "ARN of the S3 bucket receiving the access logs. Need not be in us-east-1; cross-Region delivery is supported. The bucket policy must grant delivery.logs.amazonaws.com s3:PutObject on the delivered prefix (see modules/s3_access_logs)."
}
