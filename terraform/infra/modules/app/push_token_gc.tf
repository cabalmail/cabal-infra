# Weekly garbage collection for stale push device tokens
# (docs/0.11.0/push-notifications.md): the backstop for token rows that
# neither push_dispatch's APNs-rejection pruning nor push_deregister's
# sign-out path can reach. Scheduled Lambda modeled on process_dmarc's
# EventBridge Scheduler wiring.

# -- IAM role for the GC Lambda ----------------------------------

resource "aws_iam_role" "push_token_gc" {
  name = "push_token_gc_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Sid       = "pushTokenGcSid"
      }
    ]
  })
}

resource "aws_iam_role_policy" "push_token_gc" {
  name = "push_token_gc_policy"
  role = aws_iam_role.push_token_gc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Scan",
          "dynamodb:DeleteItem",
        ]
        Resource = "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/cabal-push-tokens"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.push_token_gc.arn}:*"
      }
    ]
  })
}

# -- Lambda function ---------------------------------------------

resource "aws_cloudwatch_log_group" "push_token_gc" {
  name              = "/cabal/lambda/push_token_gc"
  retention_in_days = 365
}

data "aws_s3_object" "push_token_gc_hash" {
  bucket = var.bucket
  key    = "lambda/push_token_gc.zip.base64sha256"
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "push_token_gc" {
  # Same posture as push_dispatch / append_sent:
  #checkov:skip=CKV_AWS_115: shared-pool concurrency is the point; a per-function reserve would starve the API lambdas
  #checkov:skip=CKV_AWS_116: scheduler-invoked housekeeping; a missed weekly run is retried next week, a DLQ would only collect noise
  #checkov:skip=CKV_AWS_117: touches only AWS APIs; a VPC placement would add a NAT dependency for zero data-plane gain
  #checkov:skip=CKV_AWS_272: code-signing is not part of this repo's Lambda supply chain (zips are hash-pinned at build; see build-api-one.sh)
  #checkov:skip=CKV_AWS_50: X-Ray tracing is not used anywhere in this stack (see the tfsec ignore above)
  s3_bucket        = var.bucket
  s3_key           = "lambda/push_token_gc.zip"
  source_code_hash = data.aws_s3_object.push_token_gc_hash.body
  function_name    = "push_token_gc"
  role             = aws_iam_role.push_token_gc.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  # A full-table scan of a small table; generous headroom over the 29s
  # API-lambda convention because nothing user-facing waits on this.
  timeout     = 120
  memory_size = 128

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.push_token_gc.name
  }

  environment {
    variables = {
      PUSH_TOKENS_TABLE_NAME = "cabal-push-tokens"
    }
  }

  depends_on = [aws_cloudwatch_log_group.push_token_gc]

  # Out-of-band Lambda deploys mutate code via aws lambda update-function-code;
  # ignore these so a topology-only Terraform apply does not roll the update
  # back (matches push_dispatch and the call module).
  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

# -- Weekly schedule ---------------------------------------------

resource "aws_iam_role" "push_token_gc_scheduler" {
  name = "cabal-push-token-gc-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "scheduler.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy" "push_token_gc_scheduler_invoke" {
  name = "cabal-push-token-gc-scheduler-invoke"
  role = aws_iam_role.push_token_gc_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.push_token_gc.arn
      }
    ]
  })
}

resource "aws_scheduler_schedule" "push_token_gc" {
  name        = "cabal-push-token-gc"
  description = "Reap push device tokens idle for 90+ days (weekly backstop)"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 60
  }

  schedule_expression = "rate(7 days)"

  target {
    arn      = aws_lambda_function.push_token_gc.arn
    role_arn = aws_iam_role.push_token_gc_scheduler.arn
  }
}
