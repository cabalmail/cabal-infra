module "cors" {
  source          = "squidfunk/api-gateway-enable-cors/aws"
  version         = "0.3.3"

  api_id          = var.gateway_id
  api_resource_id = aws_api_gateway_resource.api_call.id
  allow_headers   = [
    "Authorization",
    "Content-Type",
    "X-Amz-Date",
    "X-Amz-Security-Token",
    "X-Api-Key",
    "origin",
    "Referer",
    "User-Agent"
  ]
}
