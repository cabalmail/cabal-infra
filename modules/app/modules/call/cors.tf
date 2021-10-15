resource "aws_api_gateway_method" "cabal_options_method" {
  rest_api_id   = var.gateway_id
  resource_id   = aws_api_gateway_resource.cabal_resource.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "cabal_options_integration" {
  rest_api_id       = var.gateway_id
  resource_id       = aws_api_gateway_resource.cabal_resource.id
  http_method       = aws_api_gateway_method.cabal_options_method.http_method
  type              = "MOCK"
  request_templates = { 
    "application/json" = <<PARAMS
{ "statusCode": 200 }
PARAMS
  }
}

resource "aws_api_gateway_integration_response" "cabal_options_integration_response" {
  rest_api_id         = var.gateway_id
  resource_id         = aws_api_gateway_resource.cabal_resource.id
  http_method         = aws_api_gateway_method.cabal_options_method.http_method
  status_code         = aws_api_gateway_method_response.cabal_options_response_proxy.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'${local.allowed_headers}'",
    "method.response.header.Access-Control-Allow-Methods" = "'${local.allowed_methods}'",
    "method.response.header.Access-Control-Allow-Origin"  = "'https://admin.${var.control_domain}'"
  }
  depends_on          = [
    aws_api_gateway_integration.cabal_options_integration
  ]
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
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
  depends_on          = [
    aws_api_gateway_method.cabal_options_method
  ]
}