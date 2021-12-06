output "efs_dns" {
  value       = aws_efs_file_system.mailstore.dns_name
  description = "Domain name of elastic filesystem."
}

output "efs_arn" {
  value       = aws_efs_file_system.mailstore.arn
  description = "ARN of elastic filesystem."
}