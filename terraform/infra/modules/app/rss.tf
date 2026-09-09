# RSS reader: fetch queue and content bucket (docs/1.x/rss-implementation-plan.md,
# phase 1). The tables live in modules/table. Nothing produces or consumes
# these until phase 2 (scheduler + fetcher Lambdas) and phase 7 (image
# proxy); phase 1 stands the resources up so every later phase is code.

# -- Fetch queue ---------------------------------------------
#
# rss_schedule (EventBridge Scheduler, every 5 minutes) claims each due feed
# and enqueues its id here; rss_fetch consumes one feed per invocation under
# a small reserved concurrency so outbound traffic to publishers stays
# polite and bounded. The split replaces a single loop-over-every-feed
# Lambda: no 15-minute ceiling, per-feed retries for free, and a DLQ that is
# the operator's signal when a feed fails in a way the health fields on its
# row did not capture.

resource "aws_sqs_queue" "rss_fetch_dlq" {
  name                      = "cabal-rss-fetch-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "rss_fetch" {
  name = "cabal-rss-fetch-queue"
  # >= the worker's function timeout (a fetch is bounded by a hard HTTP
  # timeout and a 5 MB response cap, well inside 120s).
  visibility_timeout_seconds = 180
  # A claim older than an hour is stale: the scheduler advanced the feed's
  # next_fetch_at when it enqueued, so an unconsumed message just means the
  # feed waits for its next cadence rather than being fetched twice.
  message_retention_seconds = 3600

  sqs_managed_sse_enabled = true

  # Three tries covers a transient publisher or network blip; a feed that
  # fails three times in a row inside one claim belongs in the DLQ, and its
  # own row's consecutive_failure_count handles the slower dead-letter.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.rss_fetch_dlq.arn
    maxReceiveCount     = 3
  })
}

# -- Content bucket ------------------------------------------
#
# Two prefixes with different lifetimes:
#   img/    proxied-and-cached publisher images (D13), expired after 7 days
#   items/  item bodies too large for a DynamoDB row (>~300 KB), kept for
#           the life of the item (D4) and deleted with it
#
# Versioning is on: items/ is authoritative (a publisher's full-text body
# that no longer exists upstream is not regenerable), and the cost is
# negligible because both prefixes are write-once - the noncurrent rule
# below exists only for the rare overwrite. Private, access-logged, and
# reached only by the RSS Lambdas; clients get presigned URLs.
resource "aws_s3_bucket" "rss_cache" {
  #checkov:skip=CKV_AWS_144:Single-region deployment by design, like every other bucket in the stack; img/ is a regenerable cache and the items/ spill is small and write-once. Replication would double storage for a solo operator with no second-region consumer.
  #checkov:skip=CKV2_AWS_62:No consumer for bucket events - the RSS Lambdas write and read by key and item lifecycle is driven from DynamoDB, not S3 notifications.
  bucket = "rss-cache.${var.control_domain}"
}

resource "aws_s3_bucket_versioning" "rss_cache" {
  bucket = aws_s3_bucket.rss_cache.bucket
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "rss_cache" {
  bucket     = aws_s3_bucket.rss_cache.bucket
  depends_on = [aws_s3_bucket_versioning.rss_cache]

  # The image-cache TTL (D13: 7 days). Operator override is a Terraform
  # change, not an SSM parameter - S3 lifecycle rules are not read at
  # request time.
  rule {
    id = "expire_images"
    filter {
      prefix = "img/"
    }
    expiration {
      days = 7
    }
    status = "Enabled"
  }
  # Bucket-wide: retire overwritten versions and abandoned multipart parts
  # (same seven days as the other cache and access-log buckets).
  rule {
    id = "retire_noncurrent_and_incomplete"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "rss_cache" {
  bucket = aws_s3_bucket.rss_cache.bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server access logs -> shared target bucket (modules/s3_access_logs), the
# CKV_AWS_18 / AWS-0089 audit trail.
resource "aws_s3_bucket_logging" "rss_cache" {
  bucket        = aws_s3_bucket.rss_cache.bucket
  target_bucket = var.access_logs_bucket
  target_prefix = "rss-cache/"
}
