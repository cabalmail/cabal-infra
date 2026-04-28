output "cluster_name" {
  value       = aws_ecs_cluster.mail.name
  description = "Name of the ECS cluster."
}

output "cluster_arn" {
  value       = aws_ecs_cluster.mail.arn
  description = "ARN of the ECS cluster."
}

output "capacity_provider_name" {
  value       = aws_ecs_capacity_provider.ec2.name
  description = "Name of the EC2 capacity provider. Consumed by non-mail services that share the cluster."
}

output "sns_topic_arn" {
  value       = aws_sns_topic.address_changed.arn
  description = "ARN of the address-changed SNS topic. Lambdas publish here to trigger reconfiguration."
}

output "imap_service_name" {
  value       = aws_ecs_service.imap.name
  description = "Name of the IMAP ECS service."
}

output "smtp_in_service_name" {
  value       = aws_ecs_service.smtp_in.name
  description = "Name of the SMTP-IN ECS service."
}

output "smtp_out_service_name" {
  value       = aws_ecs_service.smtp_out.name
  description = "Name of the SMTP-OUT ECS service."
}

# Target group ARNs — used to switch NLB listeners during cutover (Phase 7).

output "imap_target_group_arn" {
  value       = aws_lb_target_group.tier["imap"].arn
  description = "ARN of the ECS IMAP target group (ip-type)."
}

output "relay_target_group_arn" {
  value       = aws_lb_target_group.tier["relay"].arn
  description = "ARN of the ECS SMTP relay target group (ip-type)."
}

output "submission_target_group_arn" {
  value       = aws_lb_target_group.tier["submission"].arn
  description = "ARN of the ECS SMTP submission target group (ip-type)."
}

output "starttls_target_group_arn" {
  value       = aws_lb_target_group.tier["starttls"].arn
  description = "ARN of the ECS SMTP STARTTLS target group (ip-type)."
}

output "tier_log_group_names" {
  value       = { for k, v in aws_cloudwatch_log_group.tier : k => v.name }
  description = "Map of mail-tier CloudWatch log group names keyed by tier (imap | smtp-in | smtp-out). Phase 4 §2 metric filters target these."
}
