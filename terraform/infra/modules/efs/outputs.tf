output "efs_dns" {
  value       = aws_efs_file_system.mailstore.dns_name
  description = "Domain name of elastic filesystem."
}

output "efs_id" {
  value       = aws_efs_file_system.mailstore.id
  description = "ID of elastic filesystem."
}

output "efs_arn" {
  value       = aws_efs_file_system.mailstore.arn
  description = "ARN of elastic filesystem."
}

output "smtp_queue_access_point_id" {
  value       = aws_efs_access_point.smtp_queue.id
  description = "EFS access point id for the shared smtp-out sendmail MTA queue."
}