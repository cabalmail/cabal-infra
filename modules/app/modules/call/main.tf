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

resource "aws_api_gateway_integration" "cabal_integration" {
  rest_api_id             = var.gateway_id
  resource_id             = aws_api_gateway_resource.cabal_resource.id
  http_method             = aws_api_gateway_method.cabal_method.http_method
  integration_http_method = "GET"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.cabal_lambda.invoke_arn
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


resource "aws_api_gateway_integration_response" "cabal_integration_response" {
  rest_api_id = var.gateway_id
  resource_id = aws_api_gateway_resource.cabal_resource.id
  http_method = aws_api_gateway_method.cabal_method.http_method
  status_code = aws_api_gateway_method_response.cabal_response_proxy.status_code
}