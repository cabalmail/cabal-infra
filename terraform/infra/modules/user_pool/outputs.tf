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
  value       = var.use_eum_sms ? aws_pinpointsmsvoicev2_phone_number.sms[0].phone_number : ""
  description = "AWS End User Messaging toll-free phone number for SMS verification. Empty string when var.use_eum_sms is false."
}

output "user_pool_domain" {
  value       = aws_cognito_user_pool_domain.users.domain
  description = "Hosted-UI domain prefix for the Cognito user pool."
}
