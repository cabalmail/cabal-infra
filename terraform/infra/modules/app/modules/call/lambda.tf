locals {
  hosted_zone_arns = join(",",[for domain in var.domains : "\"${domain.arn}\""])
  wildcard         = "*"
  filename         = "python" ? "function.py" : "index.js"
  path             = "${path.module}/../../../../../../lambda/${var.type}/${var.name}/"
  zip_file         = "${var.name}_lambda.zip"
}

resource "random_string" "build_path" {
  length  = 32
  special = false
}

resource "null_resource" "install_dependencies" {
  count = var.type == "python" ? 1 : 0
  provisioner "local-exec" {
    command = <<-EOT
      mkdir ${path.module}/${random_string.build_path.id}
      cp ${local.path}/${local.filename} ${path.module}/${random_string.build_path.id}/
      cd build
      pip install -r ${var.lambda_root}/requirements.txt -t ./
    EOT
  }

  triggers = {
    dependencies_versions = filemd5("${local.path}/requirements.txt")
    source_versions       = filemd5("${local.path}/function.py")
  }
}

data "archive_file" "python_code" {
  count       = type == "python" ? 1 : 0
  type        = "zip"
  output_path = local.zip_file

  depends_on  = [null_resource.install_dependencies]
  excludes    = [
    "__pycache__",
    "venv",
  ]

  source_dir  = random_string.build_path.id
}

data "archive_file" "node_code" {
  count       = type == "node" ? 1 : 0
  type        = "zip"
  output_path = "${var.name}_lambda.zip"

  source {
    content  = templatefile("${local.path}/${local.filename}", {
      control_domain = var.control_domain
      repo           = var.repo
      domains        = {for domain in var.domains : domain.domain => domain.zone_id}
      })
    filename = local.filename
  }
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
      "Sid": "${var.name}Sid"
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
            "Action": "logs:CreateLogGroup",
            "Resource": "arn:aws:logs:${var.region}:${var.account}:${local.wildcard}"
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

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "api_call" {
  filename         = type == "python" ? data.archive_file.python_code[0].output_path : data.archive_file.node_code[0].output_path
  source_code_hash = data.archive_file.code.output_base64sha256
  function_name    = var.name
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = var.runtime
}

resource "null_resource" "cleanup" {
  count = var.type == "python" ? 1 : 0
  provisioner "local-exec" {
    command = "rmdir -Rf ${path.module}/${random_string.build_path.id}"
  }

  depends_on = [
    aws_lambda_function.api_call
  ]
}
