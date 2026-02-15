output "user_pool_id" {
  value       = aws_cognito_user_pool.users.id
  description = "ID of the Cognito user pool"
}

output "user_pool_arn" {
  value       = aws_cognito_user_pool.users.arn
  description = "ARN of the Cognito user pool"
}

output "user_pool_client_id" {
  value       = aws_cognito_user_pool_client.users.id
  description = "ID for the client application of the Cognito user pool"
}
