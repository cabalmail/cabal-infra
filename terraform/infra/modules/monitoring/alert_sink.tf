# -- alert_sink Lambda ------------------------------------------
#
# Built by .github/scripts/build-api.sh from lambda/api/alert_sink/.
# Exposed via a Lambda Function URL (no API Gateway) so it is reachable
# from Kuma's webhook provider without CloudFront / Cognito routing.
# Authentication is enforced inside the function against a shared secret
# in SSM Parameter Store. The function fans out to Pushover (critical)
# and self-hosted ntfy (critical + warning).

data "aws_s3_object" "alert_sink_hash" {
  bucket = var.lambda_bucket
  key    = "lambda/alert_sink.zip.base64sha256"
}

resource "aws_iam_role" "alert_sink" {
  name = "alert_sink_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "alert_sink" {
  name = "alert_sink_policy"
  role = aws_iam_role.alert_sink.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          aws_ssm_parameter.alert_secret.arn,
          aws_ssm_parameter.pushover_user_key.arn,
          aws_ssm_parameter.pushover_app_token.arn,
          aws_ssm_parameter.ntfy_publisher_token.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/cabal/lambda/alert_sink:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "alert_sink" {
  name              = "/cabal/lambda/alert_sink"
  retention_in_days = 14
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "alert_sink" {
  s3_bucket        = var.lambda_bucket
  s3_key           = "lambda/alert_sink.zip"
  source_code_hash = data.aws_s3_object.alert_sink_hash.body
  function_name    = "alert_sink"
  role             = aws_iam_role.alert_sink.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 10
  memory_size      = 128

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.alert_sink.name
  }

  environment {
    variables = {
      SHARED_SECRET_PARAM        = aws_ssm_parameter.alert_secret.name
      PUSHOVER_USER_KEY_PARAM    = aws_ssm_parameter.pushover_user_key.name
      PUSHOVER_APP_TOKEN_PARAM   = aws_ssm_parameter.pushover_app_token.name
      NTFY_PUBLISHER_TOKEN_PARAM = aws_ssm_parameter.ntfy_publisher_token.name
      NTFY_BASE_URL              = "https://ntfy.${var.control_domain}"
      NTFY_TOPIC                 = var.ntfy_topic
    }
  }

  depends_on = [aws_cloudwatch_log_group.alert_sink]
}

# Lambda Function URL: public HTTPS endpoint authenticated by the shared
# secret in the function. Kuma's webhook provider posts here.

resource "aws_lambda_function_url" "alert_sink" {
  function_name      = aws_lambda_function.alert_sink.function_name
  authorization_type = "NONE"

  cors {
    allow_methods = ["POST"]
    allow_origins = ["*"]
    allow_headers = ["content-type", "x-alert-secret"]
  }
}

# Function URLs with authorization_type = NONE require TWO statements
# in the function's resource policy: lambda:InvokeFunctionUrl satisfies
# the URL gateway's auth-layer check, and lambda:InvokeFunction (scoped
# to URL callers via lambda:InvokedViaFunctionUrl=true) satisfies the
# execute layer. Missing either returns 403 at the URL gateway.
# Authentication is enforced inside the function via the X-Alert-Secret
# header, so the public principal is intentional.

resource "aws_lambda_permission" "alert_sink_url" {
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.alert_sink.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "alert_sink_url_invoke" {
  statement_id             = "FunctionURLInvokeAllowPublicAccess"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.alert_sink.function_name
  principal                = "*"
  invoked_via_function_url = true
}
