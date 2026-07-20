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
  value       = var.ten_dlc_campaign_registration_id != "" ? aws_pinpointsmsvoicev2_phone_number.ten_dlc[0].phone_number : ""
  description = "AWS End User Messaging 10DLC phone number for SMS verification. Empty string when no campaign registration id is set."
}

output "user_pool_domain" {
  value       = aws_cognito_user_pool_domain.users.domain
  description = "Hosted-UI domain prefix for the Cognito user pool."
}

output "invitation_required" {
  value       = var.invitation_code != ""
  description = "True when the check_invite pre-signup Lambda enforces an invitation code. Consumed by the app module so the React signup form can hide the field when no code is configured."
}
