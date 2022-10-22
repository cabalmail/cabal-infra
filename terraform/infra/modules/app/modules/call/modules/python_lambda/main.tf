locals {
  hosted_zone_arns = join(",",[for domain in var.domains : "\"${domain.arn}\""])
  wildcard         = "*"
  filename         = "function.py"
  path             = "../../lambda/python/${var.name}"
  zip_file         = "./${var.name}_lambda.zip"
  build_path       = "${path.module}/build_path"
}

resource "null_resource" "python_build" {
  provisioner "local-exec" {
    command     = <<-EOT
      set -e
      cp ${local.path}/requirements.txt ${local.build_path}/
      cat <<EOF > ${local.build_path}/${local.filename}
      ${templatefile("${local.path}/${local.filename}", {
        control_domain = var.control_domain
      })}
      EOF
      pip install -r ${local.path}/requirements.txt -t ${local.build_path}
      find ${local.build_path}/ -exec touch -t 201301250000 \{\} \;
      EOT
  }
  triggers = {
    always_run = "${timestamp()}"
    zip_file   = local.zip_file
  }
}

data "archive_file" "python_code" {
  type        = "zip"
  output_path = local.zip_file
  source_dir  = local.build_path
  excludes    = [
    "__pycache__",
    "venv",
  ]
  depends_on   = [
    null_resource.python_build
  ]
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
    var.method,
    var.call_path
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
  filename         = data.archive_file.python_code.output_path
  source_code_hash = data.archive_file.python_code.output_base64sha256
  function_name    = var.name
  role             = aws_iam_role.lambda.arn
  handler          = "function.handler"
  runtime          = var.runtime
  timeout          = 30
}

resource "null_resource" "cleanup" {
  provisioner "local-exec" {
    command = "rm -Rf ${local.build_path} ${local.zip_file}"
  }

  depends_on = [
    aws_lambda_function.api_call
  ]
}
