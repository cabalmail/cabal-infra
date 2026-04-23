output "alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "ARN of the cabal-alerts SNS topic. Future phases publish here via the alert_sms Lambda."
}

output "alert_sms_function_url" {
  value       = aws_lambda_function_url.alert_sms.function_url
  description = "HTTPS endpoint for the alert_sms Lambda. Configure Kuma's webhook provider with this URL and the X-Alert-Secret header."
}

output "alert_secret_parameter_name" {
  value       = aws_ssm_parameter.alert_secret.name
  description = "SSM Parameter Store name holding the shared webhook secret."
}

output "uptime_url" {
  value       = "https://uptime.${var.control_domain}/"
  description = "Cognito-authenticated URL for the Uptime Kuma UI."
}
