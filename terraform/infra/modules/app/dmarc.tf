# DMARC report ingestion pipeline: DynamoDB table, Lambda, IAM, and EventBridge schedule.

# ── DynamoDB table for parsed DMARC report records ──────────

#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "dmarc_reports" {
  name         = "cabal-dmarc-reports"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }
  point_in_time_recovery {
    enabled = true
  }
}

# ── IAM role for the process_dmarc Lambda ───────────────────

resource "aws_iam_role" "process_dmarc" {
  name = "process_dmarc_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Sid       = "processDmarcSid"
      }
    ]
  })
}

resource "aws_iam_role_policy" "process_dmarc" {
  name = "process_dmarc_policy"
  role = aws_iam_role.process_dmarc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:DescribeParameters"]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/cabal/master_password"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = aws_dynamodb_table.dmarc_reports.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.process_dmarc.arn}:*"
      }
    ]
  })
}

# ── Lambda function ─────────────────────────────────────────

resource "aws_cloudwatch_log_group" "process_dmarc" {
  name              = "/cabal/lambda/process_dmarc"
  retention_in_days = 14
}

data "aws_s3_object" "process_dmarc_hash" {
  bucket = var.bucket
  key    = "lambda/process_dmarc.zip.base64sha256"
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "process_dmarc" {
  s3_bucket        = var.bucket
  s3_key           = "lambda/process_dmarc.zip"
  source_code_hash = data.aws_s3_object.process_dmarc_hash.body
  layers           = [var.layers["python"]]
  function_name    = "process_dmarc"
  role             = aws_iam_role.process_dmarc.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 512

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.process_dmarc.name
  }

  environment {
    variables = {
      CONTROL_DOMAIN   = var.control_domain
      DMARC_TABLE_NAME = aws_dynamodb_table.dmarc_reports.name
      DMARC_USER       = "dmarc"
    }
  }

  depends_on = [aws_cloudwatch_log_group.process_dmarc]
}

# ── EventBridge Scheduler (every 6 hours) ───────────────────

resource "aws_iam_role" "dmarc_scheduler" {
  name = "cabal-dmarc-scheduler"

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

resource "aws_iam_role_policy" "dmarc_scheduler_invoke" {
  name = "invoke-process-dmarc"
  role = aws_iam_role.dmarc_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.process_dmarc.arn
      }
    ]
  })
}

resource "aws_scheduler_schedule" "process_dmarc" {
  name        = "cabal-process-dmarc"
  description = "Ingest DMARC aggregate reports every 6 hours"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 30
  }

  schedule_expression = "rate(6 hours)"

  target {
    arn      = aws_lambda_function.process_dmarc.arn
    role_arn = aws_iam_role.dmarc_scheduler.arn
  }
}
