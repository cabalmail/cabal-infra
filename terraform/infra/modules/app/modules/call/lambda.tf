locals {
  hosted_zone_arns = join(",",[for domain in var.domains : "\"${domain.arn}\""])
  wildcard         = "*"
  filename         = var.type == "python" ? "function.py" : "index.js"
  path             = "${path.module}/../../../../../../lambda/${var.type}/${var.name}/"
  zip_file         = "${var.name}_lambda.zip"
  build_path       = "${path.module}/${var.name}"
}

resource "null_resource" "python_build" {
  count = var.type == "python" ? 1 : 0
  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ${local.build_path}
      cp ${local.path}/requirements.txt ${local.build_path}/
      cat <<EOF > ${local.build_path}/${local.filename}
      ${templatefile("${local.path}/${local.filename}", {
        control_domain = var.control_domain
        repo           = var.repo
        domains        = {for domain in var.domains : domain.domain => domain.zone_id}
      })}
      EOF
      pip install -r ${local.path}/requirements.txt -t ${local.build_path}
      zip -j ${local.zip_file} ${local.build_path}
    EOT
  }

  triggers = {
    dependencies_versions = filemd5("${local.path}/requirements.txt")
    source_versions       = filemd5("${local.path}/${local.filename}")
  }
}

# # h/t https://stackoverflow.com/questions/40744575/how-to-run-command-before-data-archive-file-zips-folder-in-terraform/58585612#58585612
# data "null_data_source" "wait_for_build" {
#   count  = var.type == "python" ? 1 : 0
#   inputs = {
#     lambda_exporter_id = "${null_resource.python_build[0].id}"
#     source_dir         = local.build_path
#   }
# }

# data "archive_file" "python_code" {
#   count       = var.type == "python" ? 1 : 0
#   type        = "zip"
#   output_path = local.zip_file
#   source_dir  = data.null_data_source.wait_for_build[0].outputs["source_dir"]
#   excludes    = [
#     "__pycache__",
#     "venv",
#   ]
# }

data "archive_file" "node_code" {
  count       = var.type == "node" ? 1 : 0
  type        = "zip"
  output_path = local.zip_file

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
  filename         = local.zip_file
  source_code_hash = filemd5(local.zip_file)
  function_name    = var.name
  role             = aws_iam_role.lambda.arn
  handler          = var.type == "python" ? "function.handler" : "index.handler"
  runtime          = var.runtime
}

resource "null_resource" "cleanup" {
  count = var.type == "python" ? 1 : 0
  provisioner "local-exec" {
    command = "rm -Rf ${local.build_path}"
  }

  depends_on = [
    aws_lambda_function.api_call
  ]
}
