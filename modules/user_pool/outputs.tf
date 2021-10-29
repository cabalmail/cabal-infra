output "user_pool_id" {
  value = aws_cognito_user_pool.cabal_pool.id
}

output "user_pool_arn" {
  value = aws_cognito_user_pool.cabal_pool.arn
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.cabal_pool_client.id
}