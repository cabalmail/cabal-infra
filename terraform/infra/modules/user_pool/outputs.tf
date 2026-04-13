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

output "admin_group_name" {
  value       = aws_cognito_user_group.admin.name
  description = "Name of the Cognito admin group"
}

output "sms_phone_number" {
  value       = aws_pinpointsmsvoicev2_phone_number.sms.phone_number
  description = "Toll-free phone number used for SMS verification"
}
