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

resource "aws_api_gateway_resource" "api_call" {
  rest_api_id = var.gateway_id
  parent_id   = var.root_resource_id
  path_part   = var.name
}

resource "aws_api_gateway_method" "api_call" {
  rest_api_id        = var.gateway_id
  resource_id        = aws_api_gateway_resource.api_call.id
  http_method        = var.method
  authorization      = "COGNITO_USER_POOLS"
  authorizer_id      = var.authorizer
  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "api_call" {
  rest_api_id             = var.gateway_id
  resource_id             = aws_api_gateway_resource.api_call.id
  http_method             = aws_api_gateway_method.api_call.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.type == "python" ? module.cabal_python_lambda[0].invoke_arn : module.cabal_node_lambda[0].invoke_arn
}

resource "aws_api_gateway_method_response" "api_call" {
  rest_api_id     = var.gateway_id
  resource_id     = aws_api_gateway_resource.api_call.id
  http_method     = aws_api_gateway_method.api_call.http_method
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
    aws_api_gateway_method.api_call
  ]
}


resource "aws_api_gateway_integration_response" "api_call" {
  rest_api_id = var.gateway_id
  resource_id = aws_api_gateway_resource.api_call.id
  http_method = aws_api_gateway_method.api_call.http_method
  status_code = aws_api_gateway_method_response.api_call.status_code
  depends_on = [
    aws_api_gateway_integration.api_call
  ]
}