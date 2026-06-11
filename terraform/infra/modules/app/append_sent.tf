# Asynchronous Sent-folder append pipeline: SQS queue + DLQ, consumer Lambda,
# IAM, and the event source mapping.
#
# /send delivers over SMTP first and never blocks on IMAP (the IMAP tier is
# single-task and has a zero-task window on every redeploy). It stages the
# Bcc-free Sent copy to S3 (sent-pending/<user>/<uuid>) and enqueues a job here;
# this consumer writes the copy to the user's Sent folder when IMAP is
# available. During a roll get_imap_client raises, the job stays queued, and SQS
# redelivers it until the new IMAP container is serving; after maxReceiveCount it
# lands in the DLQ.

# -- Queues --------------------------------------------------

resource "aws_sqs_queue" "append_sent_dlq" {
  name                      = "cabal-append-sent-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "append_sent" {
  name                       = "cabal-append-sent"
  visibility_timeout_seconds = 120   # >= the consumer's 60s function timeout
  message_retention_seconds  = 86400 # 1 day
  sqs_managed_sse_enabled    = true

  # ~10 retries at the 120s visibility timeout is ~20 min of redelivery, which
  # comfortably outlasts a normal IMAP roll; a genuinely stuck job then DLQs.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.append_sent_dlq.arn
    maxReceiveCount     = 10
  })
}

# -- IAM role for the consumer Lambda ------------------------

resource "aws_iam_role" "append_sent" {
  name = "append_sent_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Sid       = "appendSentSid"
      }
    ]
  })
}

resource "aws_iam_role_policy" "append_sent" {
  name = "append_sent_policy"
  role = aws_iam_role.append_sent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/cabal/master_password",
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/cabal/maintenance/imap",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:DeleteObject",
        ]
        Resource = "arn:aws:s3:::cache.${var.control_domain}/sent-pending/*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.append_sent.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.append_sent.arn}:*"
      }
    ]
  })
}

# -- Lambda function -----------------------------------------

resource "aws_cloudwatch_log_group" "append_sent" {
  name              = "/cabal/lambda/append_sent"
  retention_in_days = 14
}

data "aws_s3_object" "append_sent_hash" {
  bucket = var.bucket
  key    = "lambda/append_sent.zip.base64sha256"
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "append_sent" {
  s3_bucket        = var.bucket
  s3_key           = "lambda/append_sent.zip"
  source_code_hash = data.aws_s3_object.append_sent_hash.body
  function_name    = "append_sent"
  role             = aws_iam_role.append_sent.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 60
  memory_size      = 512

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.append_sent.name
  }

  depends_on = [aws_cloudwatch_log_group.append_sent]

  # Out-of-band Lambda deploys mutate code via aws lambda update-function-code;
  # ignore these so a topology-only Terraform apply does not roll the update
  # back (matches process_dmarc and the call module).
  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

resource "aws_lambda_event_source_mapping" "append_sent" {
  event_source_arn = aws_sqs_queue.append_sent.arn
  function_name    = aws_lambda_function.append_sent.arn

  # One job per invocation: a single failing append retries on its own rather
  # than failing a whole batch and re-running already-appended siblings.
  batch_size = 1
}
