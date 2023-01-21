output "hash_key" {
  value = <<HASHKEY
${jsonencode(aws_api_gateway_resource.api_call)}
${jsonencode(aws_api_gateway_method.api_call)}
${jsonencode(aws_api_gateway_integration.api_call)}
${jsonencode(aws_api_gateway_method_response.api_call)}
${jsonencode(aws_api_gateway_integration_response.api_call)}
HASHKEY
}