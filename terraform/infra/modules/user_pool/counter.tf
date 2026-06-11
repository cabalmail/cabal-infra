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
  name = "assign_osid_policy"
  role = aws_iam_role.for_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          # Scope to this pool's ARN, not userpool/*. The post-confirmation
          # trigger only ever updates the user that fired it, in this pool;
          # the wildcard would have let it AdminUpdateUserAttributes on any
          # user in any pool in the account.
          Effect   = "Allow"
          Action   = "cognito-idp:AdminUpdateUserAttributes"
          Resource = aws_cognito_user_pool.users.arn
        },
        {
          Effect   = "Allow"
          Action   = "dynamodb:UpdateItem"
          Resource = aws_dynamodb_table.counter.arn
        },
        {
          # logs:CreateLogGroup only ever targets this Lambda's own log group
          # (pre-created above), so scope it there rather than every group in
          # the account. Bare group ARN, no ":*" suffix: the log-group
          # resource grammar has no trailing segment, and the IAM simulator
          # shows the suffixed pattern fails to match (the suffix belongs on
          # the log-stream statement below).
          Effect   = "Allow"
          Action   = "logs:CreateLogGroup"
          Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/assign_osid"
        },
        {
          Effect = "Allow"
          Action = [
            "logs:CreateLogStream",
            "logs:PutLogEvents",
          ]
          Resource = [
            # iam-wildcard-ok: log-stream names are runtime-generated; the
            # group segment is pinned, the stream segment cannot be.
            "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/assign_osid:${local.wildcard}",
          ]
        },
        {
          # iam-wildcard-ok: rolls every mail-tier service after a signup;
          # the service names are owned by the ecs module, so this is scoped
          # to the cabal cluster path rather than named per service.
          Effect   = "Allow"
          Action   = "ecs:UpdateService"
          Resource = "arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:service/${var.ecs_cluster_name}/${local.wildcard}"
        },
      ],
      var.healthcheck_ping_param != "" ? [{
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.healthcheck_ping_param}"
      }] : []
    )
  })
}

# CloudWatch log group for the Lambda. Declared explicitly so the
# retention is bounded (14 days is plenty - the function fires only at
# Cognito signup confirmation). Without this resource AWS auto-creates
# the log group on first invocation with "Never Expire" retention,
# leaving the last "Never Expire" log-group gap in the repo.
#
# Existing environments (stage, prod) already have an auto-created log
# group; an `import` block at the root (terraform/infra/main.tf) adopts
# it on first apply. Terraform requires `import` blocks to live in the
# root module, hence the split.
resource "aws_cloudwatch_log_group" "assign_osid" {
  name              = "/aws/lambda/assign_osid"
  retention_in_days = 14
}

resource "aws_lambda_function" "assign_osid" {
  s3_bucket        = var.bucket
  s3_key           = "lambda/assign_osid.zip"
  source_code_hash = data.aws_s3_object.lambda_function_hash.body
  function_name    = "assign_osid"
  role             = aws_iam_role.for_lambda.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 30

  # Ensure the log group exists (with our retention setting) before
  # the Lambda is created, so AWS does not auto-create one with the
  # default "Never Expire" retention on first invocation.
  depends_on = [aws_cloudwatch_log_group.assign_osid]

  environment {
    variables = {
      ECS_CLUSTER_NAME       = var.ecs_cluster_name
      HEALTHCHECK_PING_PARAM = var.healthcheck_ping_param
    }
  }

  # Phase 2 of docs/0.9.x/build-deploy-simplification-plan.md: out-of-band
  # Lambda deploys mutate code via aws lambda update-function-code; ignore
  # these attributes so a topology-only Terraform apply does not roll the
  # update back.
  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
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
  item = jsonencode({
    counter = { S = "counter" }
    osid    = { N = "65535" }
    enabled = { BOOL = false }
  })
  lifecycle {
    ignore_changes = [item]
  }
}
