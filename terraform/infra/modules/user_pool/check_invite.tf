/**
* Pre-signup Cognito trigger that gates new account creation on a
* shared invitation code. The code itself is passed in via
* var.invitation_code and surfaced to the Lambda as the INVITATION_CODE
* env var; when empty (the default) the Lambda short-circuits and lets
* every signup through.
*
* Bootstrap: this module self-seeds the Lambda zip on first apply so
* that Terraform does not chicken-and-egg against app.yml. archive_file
* packages a placeholder handler locally; two aws_s3_object resources
* upload the zip and its base64sha256 sidecar to the same keys app.yml
* writes to. lifecycle.ignore_changes on the S3 objects (and the Lambda's
* code-identity attributes) lets app.yml's out-of-band updates win once
* the real code ships, without Terraform reverting them.
*/

data "archive_file" "check_invite_placeholder" {
  type        = "zip"
  output_path = "${path.module}/.terraform/check_invite_placeholder.zip"
  source {
    content  = "def handler(event, _context):\n    return event\n"
    filename = "function.py"
  }
}

resource "aws_s3_object" "check_invite_zip" {
  bucket = var.bucket
  key    = "lambda/check_invite.zip"
  source = data.archive_file.check_invite_placeholder.output_path
  etag   = data.archive_file.check_invite_placeholder.output_md5

  lifecycle {
    ignore_changes = [source, etag, content, content_base64, source_hash, version_id, metadata]
  }
}

resource "aws_s3_object" "check_invite_hash" {
  bucket       = var.bucket
  key          = "/lambda/check_invite.zip.base64sha256"
  content      = data.archive_file.check_invite_placeholder.output_base64sha256
  content_type = "text/plain"

  lifecycle {
    ignore_changes = [content, etag, source, source_hash, version_id]
  }
}

resource "aws_iam_role" "check_invite" {
  name               = "check_invite"
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

resource "aws_iam_role_policy" "check_invite" {
  name = "check_invite_policy"
  role = aws_iam_role.check_invite.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "logs:CreateLogGroup"
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${local.wildcard}"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/check_invite:${local.wildcard}",
        ]
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "check_invite" {
  name              = "/aws/lambda/check_invite"
  retention_in_days = 14
}

resource "aws_lambda_function" "check_invite" {
  s3_bucket        = aws_s3_object.check_invite_zip.bucket
  s3_key           = aws_s3_object.check_invite_zip.key
  source_code_hash = data.archive_file.check_invite_placeholder.output_base64sha256
  function_name    = "check_invite"
  role             = aws_iam_role.check_invite.arn
  handler          = "function.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 5

  depends_on = [
    aws_cloudwatch_log_group.check_invite,
    aws_s3_object.check_invite_zip,
  ]

  environment {
    variables = {
      INVITATION_CODE = var.invitation_code
    }
  }

  # Matches the assign_osid pattern: out-of-band Lambda deploys mutate
  # code via aws lambda update-function-code; ignore those attributes
  # so a topology-only Terraform apply does not roll the update back.
  # See phase 2 of docs/0.9.x/build-deploy-simplification-plan.md.
  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

resource "aws_lambda_permission" "allow_cognito_check_invite" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.check_invite.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.users.arn
}
