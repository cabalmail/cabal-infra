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
  integration_http_method = "POST"
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
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
  depends_on = [
    aws_api_gateway_method.cabal_method
  ]
}


resource "aws_api_gateway_integration_response" "cabal_integration_response" {
  rest_api_id = var.gateway_id
  resource_id = aws_api_gateway_resource.cabal_resource.id
  http_method = aws_api_gateway_method.cabal_method.http_method
  status_code = aws_api_gateway_method_response.cabal_response_proxy.status_code
  depends_on = [
    aws_api_gateway_integration.cabal_integration
  ]
}