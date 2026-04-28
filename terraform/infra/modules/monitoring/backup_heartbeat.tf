# -- backup_heartbeat Lambda + EventBridge rule (Phase 2) -------
#
# AWS Backup emits `Backup Job State Change` events to the default
# event bus on completion (success and failure). EventBridge invokes
# this Lambda only on the COMPLETED state, and the Lambda pings
# Healthchecks if a ping URL is configured. If `var.backup` is false
# in the parent stack, no Backup events ever fire, so this rule is
# inert - no need to gate it independently.

data "aws_s3_object" "backup_heartbeat_hash" {
  bucket = var.lambda_bucket
  key    = "lambda/backup_heartbeat.zip.base64sha256"
}

resource "aws_iam_role" "backup_heartbeat" {
  name = "backup_heartbeat_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "backup_heartbeat" {
  name = "backup_heartbeat_policy"
  role = aws_iam_role.backup_heartbeat.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = [aws_ssm_parameter.healthcheck_ping["aws_backup"].arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/cabal/lambda/backup_heartbeat:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "backup_heartbeat" {
  name              = "/cabal/lambda/backup_heartbeat"
  retention_in_days = 14
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "backup_heartbeat" {
  s3_bucket        = var.lambda_bucket
  s3_key           = "lambda/backup_heartbeat.zip"
  source_code_hash = data.aws_s3_object.backup_heartbeat_hash.body
  function_name    = "backup_heartbeat"
  role             = aws_iam_role.backup_heartbeat.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 10
  memory_size      = 128

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.backup_heartbeat.name
  }

  environment {
    variables = {
      HEALTHCHECK_PING_PARAM = aws_ssm_parameter.healthcheck_ping["aws_backup"].name
    }
  }

  depends_on = [aws_cloudwatch_log_group.backup_heartbeat]
}

resource "aws_cloudwatch_event_rule" "backup_completed" {
  name        = "cabal-backup-completed"
  description = "Fires the backup_heartbeat Lambda on AWS Backup job completion."

  event_pattern = jsonencode({
    source      = ["aws.backup"]
    detail-type = ["Backup Job State Change"]
    detail = {
      state = ["COMPLETED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "backup_completed" {
  rule = aws_cloudwatch_event_rule.backup_completed.name
  arn  = aws_lambda_function.backup_heartbeat.arn
}

resource "aws_lambda_permission" "backup_heartbeat_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backup_heartbeat.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.backup_completed.arn
}
