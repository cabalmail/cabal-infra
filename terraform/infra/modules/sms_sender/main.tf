/**
* Creates a KMS key and SSM parameters for Twilio SMS sender Lambda trigger.
* Also defines the Lambda function for sending Cognito SMS via Twilio.
*/

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  wildcard = "*"
}

# KMS key for Cognito to encrypt verification codes.
#
# bypass_policy_lockout_safety_check is set because the safety check
# refuses to create the key when it can't prove the calling principal
# (the GHA deploy IAM user) has kms:PutKeyPolicy through the root
# delegation, even though the policy below grants kms:* to account
# root. The policy stays manageable via the root principal, so
# bypassing the check is safe.
resource "aws_kms_key" "sms_sender" {
  description                        = "KMS key for Cognito SMS sender"
  deletion_window_in_days            = 7
  enable_key_rotation                = true
  bypass_policy_lockout_safety_check = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow Cognito to encrypt"
        Effect = "Allow"
        Principal = {
          Service = "cognito-idp.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "Allow Lambda to decrypt"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.lambda.arn
        }
        Action = [
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "sms_sender" {
  name          = "alias/sms_sender"
  target_key_id = aws_kms_key.sms_sender.key_id
}

# SSM SecureString parameters for Twilio credentials
resource "aws_ssm_parameter" "twilio_account_sid" {
  name        = "/cabal/twilio/account_sid"
  description = "Twilio Account SID for SMS sending"
  type        = "SecureString"
  value       = var.twilio_account_sid
  key_id      = aws_kms_key.sms_sender.id
  overwrite   = true
  tags = {
    Name = "twilio-account-sid"
  }
}

resource "aws_ssm_parameter" "twilio_api_key" {
  name        = "/cabal/twilio/api_key"
  description = "Twilio API key for SMS sending"
  type        = "SecureString"
  value       = var.twilio_api_key
  key_id      = aws_kms_key.sms_sender.id
  overwrite   = true
  tags = {
    Name = "twilio-api-key"
  }
}

resource "aws_ssm_parameter" "twilio_api_secret" {
  name        = "/cabal/twilio/api_secret"
  description = "Twilio API secret for SMS sending"
  type        = "SecureString"
  value       = var.twilio_api_secret
  key_id      = aws_kms_key.sms_sender.id
  overwrite   = true
  tags = {
    Name = "twilio-api-secret"
  }
}

resource "aws_ssm_parameter" "twilio_from_number" {
  name        = "/cabal/twilio/from_number"
  description = "Twilio phone number for SMS sending"
  type        = "String"
  value       = var.twilio_from_number
  overwrite   = true
  tags = {
    Name = "twilio-from-number"
  }
}

# IAM role and policy for the Lambda function
resource "aws_iam_role" "lambda" {
  name = "sms_sender"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "sms_sender_policy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/sms_sender:${local.wildcard}"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = aws_kms_key.sms_sender.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = [
          aws_ssm_parameter.twilio_account_sid.arn,
          aws_ssm_parameter.twilio_api_key.arn,
          aws_ssm_parameter.twilio_api_secret.arn,
          aws_ssm_parameter.twilio_from_number.arn
        ]
      }
    ]
  })
}

# Lambda function for sending SMS via Twilio
data "aws_s3_object" "lambda_function_hash" {
  bucket = var.bucket
  key    = "/lambda/sms_sender.zip.base64sha256"
}

resource "aws_lambda_function" "sms_sender" {
  s3_bucket        = var.bucket
  s3_key           = "lambda/sms_sender.zip"
  source_code_hash = data.aws_s3_object.lambda_function_hash.body
  function_name    = "sms_sender"
  role             = aws_iam_role.lambda.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 30

  environment {
    variables = {
      TWILIO_ACCOUNT_SID_PARAM = aws_ssm_parameter.twilio_account_sid.name
      TWILIO_API_KEY_PARAM     = aws_ssm_parameter.twilio_api_key.name
      TWILIO_API_SECRET_PARAM  = aws_ssm_parameter.twilio_api_secret.name
      TWILIO_FROM_NUMBER_PARAM = aws_ssm_parameter.twilio_from_number.name
      KMS_KEY_ID               = aws_kms_key.sms_sender.arn
    }
  }

  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

# Permission for Cognito to invoke the Lambda
resource "aws_lambda_permission" "cognito_invoke" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sms_sender.function_name
  principal     = "cognito-idp.amazonaws.com"
}
