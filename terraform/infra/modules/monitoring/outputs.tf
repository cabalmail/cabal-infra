output "alert_sink_function_url" {
  value       = aws_lambda_function_url.alert_sink.function_url
  description = "HTTPS endpoint for the alert_sink Lambda. Configure Kuma's webhook provider with this URL and the X-Alert-Secret header."
}

output "alert_secret_parameter_name" {
  value       = aws_ssm_parameter.alert_secret.name
  description = "SSM Parameter Store name holding the shared webhook secret."
}

output "pushover_user_key_parameter_name" {
  value       = aws_ssm_parameter.pushover_user_key.name
  description = "SSM Parameter Store name for the Pushover user key. Operator populates out-of-band."
}

output "pushover_app_token_parameter_name" {
  value       = aws_ssm_parameter.pushover_app_token.name
  description = "SSM Parameter Store name for the Pushover application token. Operator populates out-of-band."
}

output "ntfy_publisher_token_parameter_name" {
  value       = aws_ssm_parameter.ntfy_publisher_token.name
  description = "SSM Parameter Store name for the ntfy publisher bearer token. Operator populates after bootstrapping the ntfy container."
}

output "uptime_url" {
  value       = "https://uptime.${var.control_domain}/"
  description = "Cognito-authenticated URL for the Uptime Kuma UI."
}

output "ntfy_url" {
  value       = "https://ntfy.${var.control_domain}/"
  description = "Public URL for the self-hosted ntfy server (token-auth enforced)."
}

output "ntfy_service_name" {
  value       = aws_ecs_service.ntfy.name
  description = "ECS service name for ntfy, used by the bootstrap runbook."
}
