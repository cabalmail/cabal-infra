data "aws_caller_identity" "current" {}

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
  rest_api_id   = var.gateway_id
  resource_id   = aws_api_gateway_resource.cabal_resource.id
  http_method   = "GET"
  authorization = "NONE"
  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "cabal_integration" {
  rest_api_id = var.gateway_id
  resource_id = aws_api_gateway_resource.cabal_resource.id
  http_method = aws_api_gateway_method.cabal_method.http_method
  integration_http_method = "GET"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.cabal_lambda.invoke_arn
 
  request_parameters =  {
    "integration.request.path.proxy" = "method.request.path.proxy"
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
      data.aws_caller_identity.current.account_id,
      var.gateway_id
    ]),
    "/*/",
    aws_api_gateway_method.cabal_method.http_method,
    aws_api_gateway_resource.cabal_resource.path
  ])
}

resource "aws_iam_role" "cabal_lambda_role" {
  name = "myrole"

  assume_role_policy = <<POLICY
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
POLICY
}

resource "aws_lambda_function" "cabal_lambda" {
  filename = "${var.name}_lambda.zip"
  source_code_hash = data.archive_file.cabal_lambda_zip.output_base64sha256
  function_name = var.name
  role = aws_iam_role.cabal_lambda_role.arn
  handler = "index.handler"
  runtime = var.runtime
}