- **CloudFront access logs for both distributions.** The admin app and
  the public front door now deliver access logs to the shared
  `cabal-s3-access-logs-<account>` bucket, alongside the S3 server access
  logs and under the same 180-day lifecycle. Delivery uses CloudWatch
  vended-log delivery (CloudFront standard logging v2, new
  `modules/cloudfront_logs`) rather than the distribution's legacy
  `logging_config` block: the legacy path authorizes delivery with a
  bucket ACL grant, and every bucket in the stack has ACLs disabled, so
  it would have meant re-enabling ACLs on a log bucket. The v2 path
  authorizes with a bucket policy instead and needs none. Delivery
  resources live in us-east-1, which CloudFront requires, while the
  destination bucket stays in the stack region.
