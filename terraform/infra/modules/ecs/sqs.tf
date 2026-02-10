/**
* SQS queues for the reconfiguration sidecar (one per tier).
*
* Each queue subscribes to the cabal-address-changed SNS topic. The
* reconfigure.sh sidecar in each container long-polls its queue and
* regenerates sendmail maps when a message arrives.
*/

# ── Queues ─────────────────────────────────────────────────────

resource "aws_sqs_queue" "imap" {
  name                       = "cabal-reconfig-imap"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 3600
}

resource "aws_sqs_queue" "smtp_in" {
  name                       = "cabal-reconfig-smtp-in"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 3600
}

resource "aws_sqs_queue" "smtp_out" {
  name                       = "cabal-reconfig-smtp-out"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 3600
}

# ── Queue policies (allow SNS to send messages) ───────────────

resource "aws_sqs_queue_policy" "imap" {
  queue_url = aws_sqs_queue.imap.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.imap.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.address_changed.arn }
      }
    }]
  })
}

resource "aws_sqs_queue_policy" "smtp_in" {
  queue_url = aws_sqs_queue.smtp_in.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.smtp_in.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.address_changed.arn }
      }
    }]
  })
}

resource "aws_sqs_queue_policy" "smtp_out" {
  queue_url = aws_sqs_queue.smtp_out.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.smtp_out.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.address_changed.arn }
      }
    }]
  })
}

# ── SNS → SQS subscriptions (fan-out) ─────────────────────────

resource "aws_sns_topic_subscription" "imap" {
  topic_arn = aws_sns_topic.address_changed.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.imap.arn
}

resource "aws_sns_topic_subscription" "smtp_in" {
  topic_arn = aws_sns_topic.address_changed.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.smtp_in.arn
}

resource "aws_sns_topic_subscription" "smtp_out" {
  topic_arn = aws_sns_topic.address_changed.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.smtp_out.arn
}
