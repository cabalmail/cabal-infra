locals {
  hosted_zone_arns = join(",",[for domain in var.domains : "\"${domain.arn}\""])
  wildcard         = "*"
  zip_file         = "s3://${var.bucket}/lambda/${var.name}_lambda.zip"
}

resource "aws_lambda_permission" "api_exec" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_call.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = join("", [
    join(":", [
      "arn:aws:execute-api",
      var.region,
      var.account,
      var.gateway_id
    ]),
    "/*/",
    aws_api_gateway_method.api_call.http_method,
    aws_api_gateway_resource.api_call.path
  ])
}

resource "aws_iam_role" "lambda" {
  name = "${var.name}_role"

  assume_role_policy = <<ROLEPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": "${replace(var.name, "_", "")}Sid"
    }
  ]
}
ROLEPOLICY
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.name}_policy"
  role   = aws_iam_role.lambda.id
  policy = <<RUNPOLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ssm:DescribeParameters"
            ],
            "Resource": "arn:aws:ssm:${var.region}:${var.account}:*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter"
            ],
            "Resource": "arn:aws:ssm:${var.region}:${var.account}:parameter/cabal/master_password"
        },
        {
            "Effect": "Allow",
            "Action": [
              "s3:ListBucket"
            ],
            "Resource": "arn:aws:s3:::cache.${var.control_domain}"
        },
        {
            "Effect": "Allow",
            "Action": [
              "s3:PutObject",
              "s3:GetObject"
            ],
            "Resource": "arn:aws:s3:::cache.${var.control_domain}/${local.wildcard}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ssm:StartSession",
                "ssm:SendCommand"
            ],
            "Resource": "arn:aws:ec2:${var.region}:${var.account}:instance/${local.wildcard}"
        },
        {
            "Effect": "Allow",
            "Action": "ssm:SendCommand",
            "Resource": "arn:aws:ssm:${var.region}:${var.account}:document/cabal_chef_document"
        },
        {
            "Effect": "Allow",
            "Action": "route53:ChangeResourceRecordSets",
            "Resource": [
              ${local.hosted_zone_arns}
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": [
                "arn:aws:logs:${var.region}:${var.account}:log-group:/aws/lambda/${aws_lambda_function.api_call.function_name}:${local.wildcard}"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:BatchGetItem",
                "dynamodb:DeleteItem",
                "dynamodb:DescribeTable",
                "dynamodb:GetItem",
                "dynamodb:ListTables",
                "dynamodb:Query",
                "dynamodb:Scan",
                "dynamodb:PutItem",
                "dynamodb:ListTagsOfResource",
                "dynamodb:ListGlobalTables",
                "dynamodb:DescribeGlobalTable"
            ],
            "Resource": [
                "arn:aws:dynamodb:${var.region}:${var.account}:table/cabal-addresses"
            ]
        }
    ]
}
RUNPOLICY
}

resource "aws_cloudwatch_log_group" "lambda_log" {
  name              = "/cabal/lambda/${var.name}"
  retention_in_days = 14
}

data "aws_s3_object" "lambda_function_hash" {
  bucket = var.bucket
  key    = "lambda/${var.name}.zip.base64sha256"
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "api_call" {
  s3_bucket        = var.bucket
  s3_key           = "lambda/${var.name}.zip"
  source_code_hash = data.aws_s3_object.lambda_function_hash.body
  layers           = var.layer_arns
  function_name    = var.name
  role             = aws_iam_role.lambda.arn
  handler          = var.type == "python" ? "function.handler" : "index.handler"
  runtime          = var.runtime
  architectures    = ["arm64"]
  timeout          = 30
  memory_size      = var.memory
  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda_log.name
  }
  environment {
    variables = {
      DOMAINS        = jsonencode({ for r in var.domains : r.domain => r.zone_id })
      CONTROL_DOMAIN = var.control_domain
    }
  }
  depends_on = [
    aws_cloudwatch_log_group.lambda_log,
  ]
}
