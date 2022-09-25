module "cors" {
  source          = "squidfunk/api-gateway-enable-cors/aws"
  version         = "0.3.3"

  api_id          = var.gateway_id
  api_resource_id = aws_api_gateway_resource.api_call.id
}

# resource "aws_api_gateway_method" "options" {
#   rest_api_id   = var.gateway_id
#   resource_id   = aws_api_gateway_resource.api_call.id
#   http_method   = "OPTIONS"
#   authorization = "NONE"
# }

# resource "aws_api_gateway_integration" "options" {
#   rest_api_id       = var.gateway_id
#   resource_id       = aws_api_gateway_resource.api_call.id
#   http_method       = aws_api_gateway_method.options.http_method
#   type              = "MOCK"
#   request_templates = { 
#     "application/json" = <<PARAMS
# { "statusCode": 200 }
# PARAMS
#   }
# }

# resource "aws_api_gateway_integration_response" "options" {
#   rest_api_id         = var.gateway_id
#   resource_id         = aws_api_gateway_resource.api_call.id
#   http_method         = aws_api_gateway_method.options.http_method
#   status_code         = aws_api_gateway_method_response.options.status_code
#   response_parameters = {
#     "method.response.header.Access-Control-Allow-Headers" = "'${local.allowed_headers}'",
#     "method.response.header.Access-Control-Allow-Methods" = "'${local.allowed_methods}'",
#     "method.response.header.Access-Control-Allow-Origin"  = "'*'"
#   }
#   depends_on          = [
#     aws_api_gateway_integration.options
#   ]
# }

# resource "aws_api_gateway_method_response" "options" {
#   rest_api_id         = var.gateway_id
#   resource_id         = aws_api_gateway_resource.api_call.id
#   http_method         = aws_api_gateway_method.options.http_method
#   status_code         = "200"
#   response_models     = {
#     "application/json" = "Empty"
#   }
#   response_parameters = {
#     "method.response.header.Access-Control-Allow-Headers" = true,
#     "method.response.header.Access-Control-Allow-Methods" = true,
#     "method.response.header.Access-Control-Allow-Origin"  = true
#   }
#   depends_on          = [
#     aws_api_gateway_method.options
#   ]
# }