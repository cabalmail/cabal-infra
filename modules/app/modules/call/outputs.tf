output "hash_key" {
  value = <<HASHKEY
${aws_api_gateway_resource.cabal_resource.id}
${aws_api_gateway_method.cabal_method.id}
${aws_api_gateway_integration.cabal_integration.id}
${aws_api_gateway_method_response.cabal_response_proxy.id}
${aws_api_gateway_integration_response.cabal_integration_response.id}
${aws_api_gateway_method.cabal_options_method.id}
${aws_api_gateway_integration.cabal_options_integration.id}
${aws_api_gateway_integration_response.cabal_options_integration_response.id}
${aws_api_gateway_method_response.cabal_options_response_proxy.id}
HASHKEY
}