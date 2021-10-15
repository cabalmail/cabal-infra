output "hash_key" {
  value = <<HASHKEY
${jsonencode(aws_api_gateway_resource.cabal_resource)}
${jsonencode(aws_api_gateway_method.cabal_method)}
${jsonencode(aws_api_gateway_integration.cabal_integration)}
${jsonencode(aws_api_gateway_method_response.cabal_response_proxy)}
${jsonencode(aws_api_gateway_integration_response.cabal_integration_response)}
${jsonencode(aws_api_gateway_method.cabal_options_method)}
${jsonencode(aws_api_gateway_integration.cabal_options_integration)}
${jsonencode(aws_api_gateway_integration_response.cabal_options_integration_response)}
${jsonencode(aws_api_gateway_method_response.cabal_options_response_proxy)}
HASHKEY
}