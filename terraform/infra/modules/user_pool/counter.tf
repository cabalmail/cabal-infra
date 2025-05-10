/**
* Creates a DynamoDB table and Lambda function to implement an atomic counter
* used for operating system user IDs.
*/

locals {
  wildcard = "*"
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
      "Action": "cognito-idp:AdminUpdateUserAttributes",
      "Resource": "arn:aws:cognito-idp:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:userpool/${local.wildcard}"
    },
    {
      "Effect": "Allow",
      "Action": "dynamodb:UpdateItem",
      "Resource": "${aws_dynamodb_table.counter.arn}"
    },
    {
      "Effect": "Allow",
      "Action": "logs:CreateLogGroup",
      "Resource": "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${local.wildcard}"
    },
    {
        "Effect": "Allow",
        "Action": "ssm:SendCommand",
        "Resource": "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:document/cabal_chef_document"
      },
    {
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:document/cabal_chef_document"
    },
    {
      "Effect": "Allow",
      "Action": [
          "ssm:StartSession",
          "ssm:SendCommand"
      ],
      "Resource": "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${local.wildcard}"
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
  role             = aws_iam_role.for_lambda.arn
  handler          = "index.handler"
  runtime          = "nodejs19.x"
  architectures    = ["arm64"]
  timeout          = 30
}

resource "aws_lambda_permission" "allow_cognito" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.assign_osid.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.users.arn
}

resource "aws_dynamodb_table" "counter" {
  name         = "cabal-counter"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "counter"

  attribute {
    name = "counter"
    type = "S"
  }
}

resource "aws_dynamodb_table_item" "seed" {
  table_name = aws_dynamodb_table.counter.name
  hash_key   = "counter"
  item       = jsonencode({
    counter = { S    = "counter" }
    osid    = { N    = "65535" }
    enabled = { BOOL = false }
  })
  lifecycle {
    ignore_changes = [item]
  }
}
