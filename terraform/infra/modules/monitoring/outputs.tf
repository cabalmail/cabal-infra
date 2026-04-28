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

output "heartbeat_url" {
  value       = "https://heartbeat.${var.control_domain}/"
  description = "Cognito-authenticated URL for the Healthchecks UI."
}

output "healthchecks_service_name" {
  value       = aws_ecs_service.healthchecks.name
  description = "ECS service name for Healthchecks, used by the bootstrap runbook."
}

output "healthcheck_ping_parameter_names" {
  value = {
    for k, p in aws_ssm_parameter.healthcheck_ping : k => p.name
  }
  description = "Map of job key to SSM Parameter Store name for the Healthchecks ping URL. Operator populates each value out-of-band after creating the corresponding check."
}

# -- Phase 3 outputs --------------------------------------------

output "metrics_url" {
  value       = "https://metrics.${var.control_domain}/"
  description = "Cognito-authenticated URL for the Grafana UI (Phase 3)."
}

output "grafana_admin_password_parameter_name" {
  value       = aws_ssm_parameter.grafana_admin_password.name
  description = "SSM Parameter Store name holding the Grafana local-admin password (auto-generated on first apply)."
}

output "prometheus_service_name" {
  value       = aws_ecs_service.prometheus.name
  description = "ECS service name for Prometheus, used by the operator runbook for ECS Exec port-forwarding."
}

output "alertmanager_service_name" {
  value       = aws_ecs_service.alertmanager.name
  description = "ECS service name for Alertmanager, used by the operator runbook."
}

output "grafana_service_name" {
  value       = aws_ecs_service.grafana.name
  description = "ECS service name for Grafana."
}
