# ── alert_sms Lambda ───────────────────────────────────────────
#
# Built by .github/scripts/build-api.sh from lambda/api/alert_sms/.
# Exposed via a Lambda Function URL (no API Gateway) so it is reachable
# from Kuma's webhook provider without CloudFront / Cognito routing.
# Authentication is enforced inside the function against a shared secret
# in SSM Parameter Store.

data "aws_s3_object" "alert_sms_hash" {
  bucket = var.lambda_bucket
  key    = "lambda/alert_sms.zip.base64sha256"
}

resource "aws_iam_role" "alert_sms" {
  name = "alert_sms_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "alert_sms" {
  name = "alert_sms_policy"
  role = aws_iam_role.alert_sms.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.alert_secret.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/cabal/lambda/alert_sms:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "alert_sms" {
  name              = "/cabal/lambda/alert_sms"
  retention_in_days = 14
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "alert_sms" {
  s3_bucket        = var.lambda_bucket
  s3_key           = "lambda/alert_sms.zip"
  source_code_hash = data.aws_s3_object.alert_sms_hash.body
  function_name    = "alert_sms"
  role             = aws_iam_role.alert_sms.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 10
  memory_size      = 128

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.alert_sms.name
  }

  environment {
    variables = {
      ALERTS_TOPIC_ARN    = aws_sns_topic.alerts.arn
      SHARED_SECRET_PARAM = aws_ssm_parameter.alert_secret.name
      SES_EMAIL_FROM      = var.ses_email_from
      SES_EMAIL_TO        = var.ses_email_to
    }
  }

  depends_on = [aws_cloudwatch_log_group.alert_sms]
}

# Lambda Function URL: public HTTPS endpoint authenticated by the shared
# secret in the function. Kuma's webhook provider posts here.

resource "aws_lambda_function_url" "alert_sms" {
  function_name      = aws_lambda_function.alert_sms.function_name
  authorization_type = "NONE"

  cors {
    allow_methods = ["POST"]
    allow_origins = ["*"]
    allow_headers = ["content-type", "x-alert-secret"]
  }
}
