data "archive_file" "cabal_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../${var.name}_source"
  output_path = "${var.name}_lambda.zip"
}

resource "aws_api_gateway_resource" "cabal_resource" {
  rest_api_id = var.gateway_id
  parent_id   = var.root_resource_id
  path_part   = var.name
}

resource "aws_api_gateway_method" "cabal_method" {
  rest_api_id        = var.gateway_id
  resource_id        = aws_api_gateway_resource.cabal_resource.id
  http_method        = var.method
  authorization      = "COGNITO_USER_POOLS"
  authorizer_id      = var.authorizer
  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_method" "cabal_options_method" {
  rest_api_id        = var.gateway_id
  resource_id        = aws_api_gateway_resource.cabal_resource.id
  http_method        = "OPTIONS"
  authorization      = "NONE"
  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "cabal_integration" {
  rest_api_id             = var.gateway_id
  resource_id             = aws_api_gateway_resource.cabal_resource.id
  http_method             = aws_api_gateway_method.cabal_method.http_method
  integration_http_method = "GET"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.cabal_lambda.invoke_arn
  request_parameters      =  {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

resource "aws_api_gateway_method_response" "cabal_response_proxy" {
  rest_api_id     = var.gateway_id
  resource_id     = aws_api_gateway_resource.cabal_resource.id
  http_method     = aws_api_gateway_method.cabal_method.http_method
  status_code     = "200"
  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_method_response" "cabal_options_response_proxy" {
  rest_api_id         = var.gateway_id
  resource_id         = aws_api_gateway_resource.cabal_resource.id
  http_method         = aws_api_gateway_method.cabal_options_method.http_method
  status_code         = "200"
  response_models     = {
    "application/json" = "Empty"
  }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "cabal_integration_response" {
  rest_api_id = var.gateway_id
  resource_id = aws_api_gateway_resource.cabal_resource.id
  http_method = aws_api_gateway_method.cabal_method.http_method
  status_code = aws_api_gateway_method_response.cabal_response_proxy.status_code
}

resource "aws_api_gateway_integration" "cabal_options_integration" {
  rest_api_id = var.gateway_id
  resource_id = aws_api_gateway_resource.cabal_resource.id
  http_method = aws_api_gateway_method.cabal_options_method.http_method
  type        = "MOCK"
}

locals {
  allowed_headers = join(",", [
    "Content-Type",
    "X-Amz-Date",
    "Authorization",
    "X-Api-Key",
    "X-Amz-Security-Token"
  ])
  allowed_methods = join(",", [
    "DELETE",
    "GET",
    "HEAD",
    "OPTIONS",
    "PATCH",
    "POST",
    "PUT"
  ])
}

resource "aws_api_gateway_integration_response" "cabal_options_integration_response" {
  rest_api_id             = var.gateway_id
  resource_id             = aws_api_gateway_resource.cabal_resource.id
  http_method             = aws_api_gateway_method.cabal_options_method.http_method
  status_code             = aws_api_gateway_method_response.cabal_options_response_proxy.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'${local.allowed_headers}'",
    "method.response.header.Access-Control-Allow-Methods" = "'${local.allowed_methods}'",
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

resource "aws_lambda_permission" "cabal_apigw_lambda_permission" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cabal_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = join("", [
    join(":", [
      "arn:aws:execute-api",
      var.region,
      var.account,
      var.gateway_id
    ]),
    "/*/",
    aws_api_gateway_method.cabal_method.http_method,
    aws_api_gateway_resource.cabal_resource.path
  ])
}

resource "aws_iam_role" "cabal_lambda_role" {
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

resource "aws_iam_policy" "cabal_lambda_policy" {
  name   = "${var.name}_policy"
  path   = "/"
  policy = <<RUNPOLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "logs:CreateLogGroup",
            "Resource": "arn:aws:logs:${var.region}:*:*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": [
                "arn:aws:logs:${var.region}:*:log-group:/aws/lambda/cabal:*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:BatchGetItem",
                "dynamodb:DescribeTable",
                "dynamodb:GetItem",
                "dynamodb:ListTables",
                "dynamodb:Query",
                "dynamodb:Scan",
                "dynamodb:ListTagsOfResource",
                "dynamodb:ListGlobalTables",
                "dynamodb:DescribeGlobalTable"
            ],
            "Resource": [
                "arn:aws:dynamodb:${var.region}:*:table/cabal-addresses"
            ]
        }
    ]
}
RUNPOLICY
}

resource "aws_iam_role_policy_attachment" "cabal_lambda_policy_attachment" {
  role       = aws_iam_role.cabal_lambda_role.name
  policy_arn = aws_iam_policy.cabal_lambda_policy.arn
}

resource "aws_lambda_function" "cabal_lambda" {
  filename = "${var.name}_lambda.zip"
  source_code_hash = data.archive_file.cabal_lambda_zip.output_base64sha256
  function_name = var.name
  role = aws_iam_role.cabal_lambda_role.arn
  handler = "index.handler"
  runtime = var.runtime
}