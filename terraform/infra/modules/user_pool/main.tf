/**
* Creates a Cognito User Pool for authentication against the management application and for authentication at the OS level (providing IMAP and SMTP authentication).
*/

locals {
  wildcard         = "*"
}

data "aws_s3_object" "lambda_function_hash" {
  bucket = var.bucket
  key    = "/lambda/assign_osid.zip.base64sha256"
}

resource "aws_iam_role" "for_lambda" {
  name               = "assign_osid"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "lambda" {
  name   = "assign_osid_policy"
  role   = aws_iam_role.for_lambda.id
  policy = <<RUNPOLICY
{
    "Version": "2012-10-17",
    "Statement": [
      {
            "Effect": "Allow",
            "Action": "logs:CreateLogGroup",
            "Resource": "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${local.wildcard}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": [
                "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/assign_osid:${local.wildcard}"
            ]
        }
    ]
}
RUNPOLICY
}

resource "aws_lambda_function" "assign_osid" {
  s3_bucket        = var.bucket
  s3_key           = "lambda/assign_osid.zip"
  source_code_hash = data.aws_s3_object.lambda_function_hash.body
  function_name    = "assign_osid"
  layers           = [var.layers["nodejs"]]
  role             = aws_iam_role.for_lambda.arn
  handler          = "index.handler"
  runtime          = "nodejs14.x"
  timeout          = 30
}

resource "aws_cognito_user_pool" "users" {
  name = "cabal"
  schema {
    name                     = "osid"
    attribute_data_type      = "Number"
    developer_only_attribute = false
    mutable                  = true
    required                 = false
    number_attribute_constraints {
      min_value = 2000
    }
  }
  lambda_config {
    post_confirmation = resource.aws_lambda_function.assign_osid.arn
  }
}

resource "aws_cognito_user_pool_client" "users" {
  name         = "cabal_admin_client"
  user_pool_id = aws_cognito_user_pool.users.id
  explicit_auth_flows = [ "USER_PASSWORD_AUTH" ]
}